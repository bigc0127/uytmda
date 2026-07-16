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

import AppKit
import QuartzCore

final class RainbowEqualizerView: NSView {
    private let barCount = 32
    private let barSpacing: CGFloat = 2
    private let minBarHeightFactor: CGFloat = 0.08
    private let maxBarHeightFactor: CGFloat = 0.95
    private let peakDotHeight: CGFloat = 3
    private let peakDecay: CGFloat = 0.012      // per tick
    private let barDecay: CGFloat = 0.08        // per tick (gravity)

    private let gradientLayer = CAGradientLayer()
    private let barsContainerLayer = CALayer()
    private var barLayers: [CALayer] = []
    private var peakLayers: [CALayer] = []
    private var barLevels: [CGFloat]    // 0...1
    private var peakLevels: [CGFloat]   // 0...1

    private var animationTimer: Timer?
    private var isPlaying: Bool = false

    /// Perceptual-loudness intensity (0...1) supplied by the macOS 27 MusicUnderstanding
    /// framework (momentary LUFS). Modulates the rainbow's overall brightness so quiet
    /// passages dim and loud passages blaze — a semantic layer on top of the raw FFT bars.
    /// Defaults to full brightness so the view looks unchanged if analysis is unavailable.
    private var energy: CGFloat = 1.0

    override init(frame frameRect: NSRect) {
        barLevels = Array(repeating: 0, count: barCount)
        peakLevels = Array(repeating: 0, count: barCount)
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        barLevels = Array(repeating: 0, count: barCount)
        peakLevels = Array(repeating: 0, count: barCount)
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setupLayers()
    }

    private func setupLayers() {
        guard let backingLayer = layer else { return }

        let colors: [CGColor] = [
            NSColor.systemRed.cgColor,
            NSColor.systemOrange.cgColor,
            NSColor.systemYellow.cgColor,
            NSColor.systemGreen.cgColor,
            NSColor.systemBlue.cgColor,
            NSColor.systemIndigo.cgColor,
            NSColor.systemPurple.cgColor
        ]
        gradientLayer.colors = colors
        gradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
        let step = 1.0 / Double(colors.count - 1)
        gradientLayer.locations = (0..<colors.count).map { NSNumber(value: Double($0) * step) }

        barsContainerLayer.masksToBounds = true
        barsContainerLayer.backgroundColor = NSColor.clear.cgColor
        gradientLayer.mask = barsContainerLayer

        backingLayer.addSublayer(gradientLayer)
        createBars()
    }

    private func createBars() {
        barLayers.forEach { $0.removeFromSuperlayer() }
        peakLayers.forEach { $0.removeFromSuperlayer() }
        barLayers.removeAll()
        peakLayers.removeAll()

        let totalSpacing = CGFloat(barCount - 1) * barSpacing
        let barWidth = max(1, (bounds.width - totalSpacing) / CGFloat(barCount))

        for i in 0..<barCount {
            let bar = CALayer()
            bar.anchorPoint = CGPoint(x: 0.5, y: 0)
            let x = CGFloat(i) * (barWidth + barSpacing) + barWidth / 2
            bar.position = CGPoint(x: x, y: 0)
            bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: 1)
            bar.cornerRadius = min(2, barWidth / 4)
            bar.backgroundColor = NSColor.white.cgColor
            barsContainerLayer.addSublayer(bar)
            barLayers.append(bar)

            let peak = CALayer()
            peak.anchorPoint = CGPoint(x: 0.5, y: 0)
            peak.position = CGPoint(x: x, y: 0)
            peak.bounds = CGRect(x: 0, y: 0, width: barWidth, height: peakDotHeight)
            peak.cornerRadius = peakDotHeight / 2
            peak.backgroundColor = NSColor.white.cgColor
            barsContainerLayer.addSublayer(peak)
            peakLayers.append(peak)
        }
    }

    override func layout() {
        super.layout()
        guard let backingLayer = layer else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.frame = backingLayer.bounds
        barsContainerLayer.frame = backingLayer.bounds

        let totalSpacing = CGFloat(barCount - 1) * barSpacing
        let barWidth = max(1, (bounds.width - totalSpacing) / CGFloat(barCount))

        for (index, bar) in barLayers.enumerated() {
            let x = CGFloat(index) * (barWidth + barSpacing) + barWidth / 2
            bar.position = CGPoint(x: x, y: 0)
            bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: bar.bounds.height)
            bar.cornerRadius = min(2, barWidth / 4)

            let peak = peakLayers[index]
            peak.position = CGPoint(x: x, y: peak.position.y)
            peak.bounds = CGRect(x: 0, y: 0, width: barWidth, height: peakDotHeight)
        }
        CATransaction.commit()
    }

    func setPlaying(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        if playing {
            startTicking()
        } else {
            stopTicking()
            // settle to zero
            barLevels = Array(repeating: 0, count: barCount)
            peakLevels = Array(repeating: 0, count: barCount)
            renderLevels(animated: true)
        }
    }

    private func startTicking() {
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            // Timer fires on the main run loop; hop the isolation to satisfy Swift 6.
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func stopTicking() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    /// Per-frame tick: applies gravity and peak decay, renders.
    private func tick() {
        guard isPlaying else { return }
        for i in 0..<barCount {
            barLevels[i] = max(0, barLevels[i] - barDecay)
            if peakLevels[i] > barLevels[i] {
                peakLevels[i] = max(barLevels[i], peakLevels[i] - peakDecay)
            } else {
                peakLevels[i] = barLevels[i]
            }
        }
        renderLevels(animated: false)
    }

    /// Public API: feed real audio levels (0...1, length should match barCount).
    func applyLevels(_ levels: [Double]) {
        guard !barLayers.isEmpty else { return }

        let mapped: [CGFloat]
        if levels.count >= barCount {
            mapped = levels.prefix(barCount).map { CGFloat(max(0, min(1, $0))) }
        } else if levels.isEmpty {
            mapped = Array(repeating: 0, count: barCount)
        } else {
            mapped = (0..<barCount).map { CGFloat(max(0, min(1, levels[$0 % levels.count]))) }
        }

        for i in 0..<barCount {
            // Lift bar level toward incoming sample (attack fast, decay slow via tick).
            barLevels[i] = max(barLevels[i], mapped[i])
            if mapped[i] > peakLevels[i] {
                peakLevels[i] = mapped[i]
            }
        }

        if animationTimer == nil { startTicking() }
        renderLevels(animated: false)
    }

    /// Public API: feed perceptual loudness (0...1) from MusicUnderstanding. Maps to the
    /// rainbow's overall brightness. Clamped and eased into a floor so the bars never fully
    /// vanish even in near-silence.
    func applyEnergy(_ value: Double) {
        let clamped = CGFloat(max(0, min(1, value)))
        // Ease toward the new value; keep a 0.45 brightness floor.
        let target = 0.45 + 0.55 * clamped
        energy += 0.25 * (target - energy)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.opacity = Float(energy)
        CATransaction.commit()
    }

    private func renderLevels(animated: Bool) {
        let h = bounds.height
        guard h > 0 else { return }

        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.18)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }

        for i in 0..<barLayers.count {
            let level = barLevels[i]
            let factor = minBarHeightFactor + (maxBarHeightFactor - minBarHeightFactor) * level
            let barHeight = max(1, h * factor)

            let bar = barLayers[i]
            var bounds = bar.bounds
            bounds.size.height = barHeight
            bar.bounds = bounds

            let peak = peakLayers[i]
            let peakFactor = minBarHeightFactor + (maxBarHeightFactor - minBarHeightFactor) * peakLevels[i]
            let peakY = max(barHeight, h * peakFactor) - peakDotHeight
            peak.position = CGPoint(x: peak.position.x, y: max(0, peakY))
            peak.opacity = peakLevels[i] > 0.05 ? 1 : 0
        }

        CATransaction.commit()
    }

}
