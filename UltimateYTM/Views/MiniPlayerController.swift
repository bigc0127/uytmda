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

@MainActor
class MiniPlayerController: NSWindowController {
    private let artworkView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "No track playing")
    private let artistLabel = NSTextField(labelWithString: "")
    private let previousButton = NSButton()
    private let playPauseButton = NSButton()
    private let nextButton = NSButton()
    private let expandButton = NSButton()

    var onPlayPause: (() async -> Void)?
    var onNext: (() async -> Void)?
    var onPrevious: (() async -> Void)?
    var onShowMainWindow: (() -> Void)?

    convenience init() {
        let window = LiquidGlassWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 110),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Mini Player"
        window.minSize = NSSize(width: 320, height: 110)
        window.maxSize = NSSize(width: 600, height: 110)
        if AppSettings.shared.miniPlayerOnTop {
            window.level = .floating
        }
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.init(window: window)
        setup()
        restoreWindowFrame()
        observeTrackUpdates()
        window.delegate = self
    }

    private func setup() {
        guard let window = window,
              let contentView = window.contentView,
              let layoutGuide = window.contentLayoutGuide as? NSLayoutGuide else { return }

        artworkView.imageScaling = .scaleProportionallyUpOrDown
        artworkView.wantsLayer = true
        artworkView.layer?.cornerRadius = 8
        artworkView.layer?.masksToBounds = true
        artworkView.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
        artworkView.contentTintColor = .secondaryLabelColor

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        artistLabel.font = .systemFont(ofSize: 11)
        artistLabel.textColor = .secondaryLabelColor
        artistLabel.lineBreakMode = .byTruncatingTail
        artistLabel.maximumNumberOfLines = 1

        configureSymbolButton(previousButton, symbol: "backward.fill", action: #selector(previousAction))
        configureSymbolButton(playPauseButton, symbol: "play.fill", action: #selector(playPauseAction), large: true)
        configureSymbolButton(nextButton, symbol: "forward.fill", action: #selector(nextAction))
        configureSymbolButton(expandButton, symbol: "arrow.up.left.and.arrow.down.right", action: #selector(expandAction))
        expandButton.toolTip = "Show Main Window"

        let textStack = NSStackView(views: [titleLabel, artistLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let controlsStack = NSStackView(views: [previousButton, playPauseButton, nextButton])
        controlsStack.orientation = .horizontal
        controlsStack.spacing = 8
        controlsStack.translatesAutoresizingMaskIntoConstraints = false

        artworkView.translatesAutoresizingMaskIntoConstraints = false
        expandButton.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(artworkView)
        contentView.addSubview(textStack)
        contentView.addSubview(controlsStack)
        contentView.addSubview(expandButton)

        let inset: CGFloat = 12
        NSLayoutConstraint.activate([
            artworkView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: inset),
            artworkView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            artworkView.widthAnchor.constraint(equalToConstant: 64),
            artworkView.heightAnchor.constraint(equalToConstant: 64),

            textStack.leadingAnchor.constraint(equalTo: artworkView.trailingAnchor, constant: 12),
            textStack.topAnchor.constraint(equalTo: layoutGuide.topAnchor, constant: 8),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: expandButton.leadingAnchor, constant: -8),

            controlsStack.leadingAnchor.constraint(equalTo: artworkView.trailingAnchor, constant: 12),
            controlsStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -inset),

            expandButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -inset),
            expandButton.topAnchor.constraint(equalTo: layoutGuide.topAnchor, constant: 8),
            expandButton.widthAnchor.constraint(equalToConstant: 24),
            expandButton.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    private func configureSymbolButton(_ button: NSButton, symbol: String, action: Selector, large: Bool = false) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
        button.imageScaling = .scaleProportionallyDown
        button.bezelStyle = .accessoryBar
        button.isBordered = false
        button.target = self
        button.action = action
        let pointSize: CGFloat = large ? 22 : 16
        button.symbolConfiguration = .init(pointSize: pointSize, weight: .medium)
        button.contentTintColor = .labelColor
    }

    func updateTrackInfo(_ info: TrackInfo) {
        titleLabel.stringValue = info.title.isEmpty ? "No track playing" : info.title
        artistLabel.stringValue = info.artist
        if let artwork = info.artworkImage {
            artworkView.image = artwork
            artworkView.contentTintColor = nil
        } else {
            artworkView.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
            artworkView.contentTintColor = .secondaryLabelColor
        }
        let symbol = info.isPaused ? "play.fill" : "pause.fill"
        playPauseButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
    }

    // MARK: - Window state

    private func observeTrackUpdates() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleTrackInfoUpdate(_:)), name: .trackInfoUpdated, object: nil)
    }

    private func restoreWindowFrame() {
        if let frame = AppSettings.shared.loadWindowFrame(forWindow: "miniPlayer") {
            window?.setFrame(frame, display: true)
        }
    }

    private func saveWindowFrame() {
        if let frame = window?.frame {
            AppSettings.shared.saveWindowFrame(frame, forWindow: "miniPlayer")
        }
    }

    // MARK: - Actions

    @objc private func playPauseAction() { Task { await onPlayPause?() } }
    @objc private func nextAction() { Task { await onNext?() } }
    @objc private func previousAction() { Task { await onPrevious?() } }
    @objc private func expandAction() { onShowMainWindow?() }

    @objc private func handleTrackInfoUpdate(_ notification: Notification) {
        guard let info = notification.object as? TrackInfo else { return }
        updateTrackInfo(info)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

extension MiniPlayerController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) { saveWindowFrame() }
}
