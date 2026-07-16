// Copyright (C) 2026 Connor Needling
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import Foundation
import ScreenCaptureKit
import AVFoundation
import Accelerate

/// Captures system audio via ScreenCaptureKit, runs FFT, emits 32 log-spaced
/// frequency-band levels (0...1) suitable for an audio visualizer.
@MainActor
class AudioCaptureManager: NSObject {
    static let shared = AudioCaptureManager()

    var onAudioLevelsUpdated: (([Double]) -> Void)?

    private var stream: SCStream?
    private let audioQueue = DispatchQueue(label: "com.ultimateytm.audiocapture")
    nonisolated(unsafe) private var fftSetup: vDSP_DFT_Setup?

    private let fftSize = 1024
    private let bandCount = 32

    /// Smoothed band levels held on the audio queue (avoids per-frame UI flicker).
    nonisolated(unsafe) private var smoothedBands: [Double] = Array(repeating: 0, count: 32)

    /// Pre-computed log-spaced FFT bin ranges per band.
    /// Filled lazily once we know the sample rate.
    nonisolated(unsafe) private var bandRanges: [(start: Int, end: Int)] = []
    /// Per-band dB gain to compensate for the natural pink-noise tilt of music
    /// (+3 dB per octave above the lowest band). Without this, low-frequency
    /// bands dominate and high-frequency bands (the violet end of the rainbow)
    /// barely register even on bright content like cymbals or sibilance.
    nonisolated(unsafe) private var bandTiltDb: [Double] = []
    nonisolated(unsafe) private var lastSampleRate: Double = 0

    override init() {
        super.init()
        fftSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD)
    }

    deinit {
        if let setup = fftSetup { vDSP_DFT_DestroySetup(setup) }
    }

    nonisolated func startCapture() async {
        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else {
                NSLog("❌ AudioCapture: no display")
                return
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = false
            config.sampleRate = 48_000
            config.channelCount = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.width = 2
            config.height = 2

            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            try await stream.startCapture()

            await MainActor.run { self.stream = stream }
            NSLog("✅ AudioCapture: started")
        } catch {
            NSLog("❌ AudioCapture start failed: \(error.localizedDescription)")
            NSLog("   Grant Screen Recording in System Settings → Privacy & Security → Screen Recording.")
        }
    }

    nonisolated func stopCapture() {
        Task { @MainActor in
            stream?.stopCapture { _ in }
            stream = nil
        }
    }

    // MARK: - Buffer processing (audio queue)

    nonisolated private func processAudioBuffer(_ buffer: CMSampleBuffer) {
        guard let setup = fftSetup else { return }
        guard let formatDesc = CMSampleBufferGetFormatDescription(buffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else { return }
        let asbd = asbdPtr.pointee

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let channels = Int(asbd.mChannelsPerFrame)
        let sampleRate = asbd.mSampleRate
        guard isFloat, channels > 0, sampleRate > 0 else { return }

        if sampleRate != lastSampleRate {
            lastSampleRate = sampleRate
            bandRanges = makeLogSpacedBands(sampleRate: sampleRate)
            bandTiltDb = makeBandTilt(sampleRate: sampleRate)
        }

        var blockBuffer: CMBlockBuffer?
        let maxBuffers = max(1, channels)
        let buffers = AudioBufferList.allocate(maximumBuffers: maxBuffers)
        defer { free(buffers.unsafeMutablePointer) }
        let ablSize = MemoryLayout<AudioBufferList>.size + (maxBuffers - 1) * MemoryLayout<AudioBuffer>.size
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: buffers.unsafeMutablePointer,
            bufferListSize: ablSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, buffers.count > 0 else { return }

        // Build a mono Float32 sample array of length fftSize.
        var mono = [Float](repeating: 0, count: fftSize)

        if isNonInterleaved {
            // One AudioBuffer per channel; mix them.
            var channelArrays: [UnsafePointer<Float>] = []
            var minFrames = Int.max
            for buf in buffers {
                guard let data = buf.mData else { continue }
                let frames = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
                channelArrays.append(data.bindMemory(to: Float.self, capacity: frames))
                minFrames = min(minFrames, frames)
            }
            let frames = min(minFrames, fftSize)
            guard frames > 0 else { return }
            for i in 0..<frames {
                var sum: Float = 0
                for arr in channelArrays { sum += arr[i] }
                mono[i] = sum / Float(channelArrays.count)
            }
        } else {
            // One AudioBuffer with interleaved channels.
            guard let data = buffers[0].mData else { return }
            let totalFloats = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
            let totalFrames = totalFloats / channels
            let frames = min(totalFrames, fftSize)
            let ptr = data.bindMemory(to: Float.self, capacity: totalFloats)
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += ptr[i * channels + c] }
                mono[i] = sum / Float(channels)
            }
        }

        // Hann window
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        vDSP_vmul(mono, 1, window, 1, &mono, 1, vDSP_Length(fftSize))

        // FFT (split-complex)
        var real = mono
        var imag = [Float](repeating: 0, count: fftSize)

        real.withUnsafeMutableBufferPointer { realBuf in
            imag.withUnsafeMutableBufferPointer { imagBuf in
                guard let r = realBuf.baseAddress, let i = imagBuf.baseAddress else { return }
                vDSP_DFT_Execute(setup, r, i, r, i)

                var split = DSPSplitComplex(realp: r, imagp: i)
                var magnitudes = [Float](repeating: 0, count: fftSize / 2)
                magnitudes.withUnsafeMutableBufferPointer { magBuf in
                    if let m = magBuf.baseAddress {
                        vDSP_zvabs(&split, 1, m, 1, vDSP_Length(fftSize / 2))
                    }
                }
                self.processMagnitudes(magnitudes)
            }
        }
    }

    nonisolated private func processMagnitudes(_ magnitudes: [Float]) {
        guard !bandRanges.isEmpty, bandTiltDb.count == bandCount else { return }

        // Average magnitudes within each band's bin range, then convert to dB-ish.
        // Tuning notes:
        //   noiseFloor lowered -60 → -78 dB so soft passages still register.
        //   topDb raised -10 → -6 dB to keep loud content from clipping the bar.
        //   release shortened so peaks settle a bit faster (looks livelier).
        let attack: Double = 0.65
        let release: Double = 0.14
        let noiseFloor: Double = -78.0  // dB
        let topDb: Double = -6.0

        var bands = [Double](repeating: 0, count: bandCount)
        for i in 0..<bandCount {
            let range = bandRanges[i]
            let count = max(1, range.end - range.start)
            var sum: Float = 0
            for k in range.start..<range.end where k < magnitudes.count {
                sum += magnitudes[k]
            }
            let avg = Double(sum / Float(count) / Float(fftSize))
            // Raw band dB, plus a +3 dB/octave pinking tilt so the high-frequency
            // (violet) bands aren't perpetually dwarfed by the low-frequency ones.
            let db = 20 * log10(max(avg, 1e-7)) + bandTiltDb[i]
            let normalized = max(0, min(1, (db - noiseFloor) / (topDb - noiseFloor)))
            bands[i] = normalized
        }

        for i in 0..<bandCount {
            let coeff = bands[i] > smoothedBands[i] ? attack : release
            smoothedBands[i] = smoothedBands[i] + coeff * (bands[i] - smoothedBands[i])
        }

        let snapshot = smoothedBands
        Task { @MainActor in
            self.onAudioLevelsUpdated?(snapshot)
        }
    }

    /// +3 dB/octave compensation across the band range (pink-noise tilt).
    /// Real-world music has far more energy in low frequencies than high ones,
    /// so without this the right-side (violet) bars look dead even on bright
    /// content. The lowest band gets 0 dB; each octave above adds +3 dB.
    nonisolated private func makeBandTilt(sampleRate: Double) -> [Double] {
        let halfSize = fftSize / 2
        let nyquist = sampleRate / 2
        let binHz = nyquist / Double(halfSize)
        let lowHz = 30.0
        let highHz = min(16_000.0, nyquist - binHz)
        let logLow = log(lowHz)
        let logHigh = log(highHz)

        var tilt = [Double](repeating: 0, count: bandCount)
        for i in 0..<bandCount {
            // Use the band's center (geometric midpoint) for the tilt curve.
            let t = (Double(i) + 0.5) / Double(bandCount)
            let centerHz = exp(logLow + t * (logHigh - logLow))
            let octavesAboveLow = log2(centerHz / lowHz)
            tilt[i] = 3.0 * octavesAboveLow
        }
        return tilt
    }

    /// Build log-spaced FFT bin ranges from ~30 Hz to ~16 kHz.
    nonisolated private func makeLogSpacedBands(sampleRate: Double) -> [(start: Int, end: Int)] {
        let halfSize = fftSize / 2
        let nyquist = sampleRate / 2
        let binHz = nyquist / Double(halfSize)

        let lowHz = 30.0
        let highHz = min(16_000.0, nyquist - binHz)
        let logLow = log(lowHz)
        let logHigh = log(highHz)

        var ranges: [(Int, Int)] = []
        var prev = max(1, Int(lowHz / binHz))
        for i in 1...bandCount {
            let t = Double(i) / Double(bandCount)
            let edgeHz = exp(logLow + t * (logHigh - logLow))
            let edgeBin = min(halfSize, Int(edgeHz / binHz))
            let start = prev
            let end = max(start + 1, edgeBin)
            ranges.append((start, end))
            prev = end
        }
        return ranges
    }
}

extension AudioCaptureManager: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        processAudioBuffer(sampleBuffer)

        // Additionally forward the raw PCM to the macOS 27 MusicUnderstanding analyzer, only
        // while it wants buffers. Failure here is silent — the FFT visualizer is unaffected.
        if MusicAnalysisFeed.shared.isActive,
           let readOnly = Self.makeReadOnlyBuffer(sampleBuffer) {
            MusicAnalysisFeed.shared.yield(readOnly)
        }
    }
}

extension AudioCaptureManager {
    /// Converts a captured audio `CMSampleBuffer` into an `AVReadOnlyAudioPCMBuffer` for
    /// MusicUnderstanding. Returns nil on any format/copy failure (caller ignores nil).
    nonisolated static func makeReadOnlyBuffer(_ sampleBuffer: CMSampleBuffer) -> AVReadOnlyAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else { return nil }
        var asbd = asbdPtr.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }

        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        pcm.frameLength = AVAudioFrameCount(frames)

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: pcm.mutableAudioBufferList
        )
        guard status == noErr else { return nil }

        return AVReadOnlyAudioPCMBuffer(copying: pcm)
    }
}
