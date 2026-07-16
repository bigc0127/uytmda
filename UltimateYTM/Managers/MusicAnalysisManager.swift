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
import AVFAudio
import MusicUnderstanding
import os

/// Thread-safe bridge between the audio-capture queue (producer) and the MusicUnderstanding
/// session (consumer). `AudioCaptureManager`'s `SCStreamOutput` callback is nonisolated, so it
/// can't touch the `@MainActor` `MusicAnalysisManager`; instead it talks to this `Sendable`
/// feed, guarded by a lock. When inactive, `yield` is a cheap no-op.
final class MusicAnalysisFeed: @unchecked Sendable {
    static let shared = MusicAnalysisFeed()

    private let lock = NSLock()
    private var continuation: AsyncStream<AVReadOnlyAudioPCMBuffer>.Continuation?
    private var active = false

    private init() {}

    /// Whether the analyzer currently wants buffers. Read from the audio queue.
    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return active
    }

    func begin(_ continuation: AsyncStream<AVReadOnlyAudioPCMBuffer>.Continuation) {
        lock.lock()
        self.continuation?.finish()
        self.continuation = continuation
        active = true
        lock.unlock()
    }

    func end() {
        lock.lock()
        continuation?.finish()
        continuation = nil
        active = false
        lock.unlock()
    }

    func yield(_ buffer: AVReadOnlyAudioPCMBuffer) {
        lock.lock()
        let continuation = self.continuation
        lock.unlock()
        continuation?.yield(buffer)
    }
}

/// Drives a semantic "energy" signal from the macOS 27 **MusicUnderstanding** framework.
///
/// `AudioCaptureManager` already runs an FFT on captured system audio for the raw visualizer
/// bars. This manager feeds the same audio (via `MusicAnalysisFeed`) into a
/// `MusicUnderstandingSession` and consumes its streaming `loudnessResults` (perceptual
/// momentary LUFS) to produce a normalized 0...1 energy value the equalizer uses to modulate
/// overall brightness.
///
/// Strictly additive and failure-tolerant: if capture yields nothing, the session errors, or
/// the OS withholds analysis, `onEnergyUpdated` simply never fires and the FFT-driven bars are
/// unaffected.
@MainActor
final class MusicAnalysisManager {
    static let shared = MusicAnalysisManager()

    private let log = Logger(subsystem: "com.ultimateytm.app", category: "MusicUnderstanding")

    /// Normalized perceptual energy (0...1), delivered on the main actor.
    var onEnergyUpdated: ((Double) -> Void)?

    private var session: MusicUnderstandingSession?
    private var loudnessTask: Task<Void, Never>?
    private(set) var isRunning = false

    private init() {}

    func start() {
        guard !isRunning else { return }
        isRunning = true

        let (stream, continuation) = AsyncStream<AVReadOnlyAudioPCMBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        MusicAnalysisFeed.shared.begin(continuation)

        let session = MusicUnderstandingSession(audioProvider: stream)
        self.session = session

        // Task created in this @MainActor method is itself main-actor-isolated, so consuming the
        // stream and calling `onEnergyUpdated` needs no extra hops or Sendable gymnastics.
        loudnessTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in session.loudnessResults {
                    // `momentary` is a series of TimedValue<Float> LUFS samples; use the latest.
                    guard let lufs = result.momentary.last?.value else { continue }
                    self.onEnergyUpdated?(Self.normalizeLUFS(Double(lufs)))
                }
                self.log.info("MusicUnderstanding loudness stream completed")
            } catch {
                self.log.error("MusicUnderstanding loudness stream error: \(String(describing: error), privacy: .public)")
            }
        }
        log.info("MusicUnderstanding analysis started")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        MusicAnalysisFeed.shared.end()
        loudnessTask?.cancel()
        loudnessTask = nil
        let session = self.session
        self.session = nil
        Task { await session?.cancel() }
    }

    /// Map momentary LUFS to 0...1. Momentary loudness of music typically sits around
    /// -40 LUFS (very quiet) to roughly -8 LUFS (loud), so anchor the ramp there.
    nonisolated static func normalizeLUFS(_ lufs: Double) -> Double {
        let quiet = -40.0
        let loud = -8.0
        guard lufs.isFinite else { return 0 }
        return max(0, min(1, (lufs - quiet) / (loud - quiet)))
    }
}
