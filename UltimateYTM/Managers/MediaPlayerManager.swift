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
import AppKit
import NowPlaying
import Observation
import os

/// System media integration, built on the macOS 27 **NowPlaying** framework
/// (`MediaSession`) rather than the legacy `MPNowPlayingInfoCenter` /
/// `MPRemoteCommandCenter`. A single `MediaSession` is the sole source of truth for
/// the system now-playing UI (Control Center, lock screen, CarPlay) and for remote
/// commands including hardware media keys.
///
/// The public surface (`on*` callbacks, `updateNowPlayingInfo(with:)`,
/// `clearNowPlayingInfo()`) is unchanged from the previous MediaPlayer-based
/// implementation, so callers in `MainWindowController` need no changes.
@MainActor
final class MediaPlayerManager: NSObject {
    static let shared = MediaPlayerManager()

    var onPlayPause: (() async -> Void)?
    var onNext: (() async -> Void)?
    var onPrevious: (() async -> Void)?
    var onSeek: ((TimeInterval) async -> Void)?

    private let log = Logger(subsystem: "com.ultimateytm.app", category: "NowPlaying")

    /// Reference type the `MediaSession` observes. Marked `@Observable` so mutations to
    /// `content` / `playbackSnapshot` propagate to the system without an explicit update
    /// call (local `MediaSession` has no `update(_:)`; it tracks the representable via
    /// Observation).
    @Observable
    @MainActor
    final class NowPlayingRepresentable: MediaSessionRepresentable {
        let id = "com.ultimateytm.app.session"
        var content: (any MediaContentRepresentable)?
        var playbackSnapshot: MediaPlaybackSnapshot?
        var commands: [MediaCommand] = []
    }

    private let representable = NowPlayingRepresentable()
    private var session: MediaSession<NowPlayingRepresentable>?

    private override init() {
        super.init()
        representable.commands = buildCommands()
        let session = MediaSession(representable)
        self.session = session
        Task { [weak self] in
            guard let self else { return }
            do {
                try await session.requestToBecomeApplicationPrimary()
                self.log.info("NowPlaying MediaSession became application-primary")
            } catch {
                self.log.error("requestToBecomeApplicationPrimary failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func buildCommands() -> [MediaCommand] {
        [
            .togglePlayPause { [weak self] in
                self?.log.debug("remote: togglePlayPause")
                await self?.onPlayPause?()
            },
            .play { [weak self] in
                self?.log.debug("remote: play")
                await self?.onPlayPause?()
            },
            .pause { [weak self] in
                self?.log.debug("remote: pause")
                await self?.onPlayPause?()
            },
            .next { [weak self] in
                self?.log.debug("remote: next")
                await self?.onNext?()
            },
            .previous { [weak self] in
                self?.log.debug("remote: previous")
                await self?.onPrevious?()
            },
            .seekToPosition { [weak self] position in
                self?.log.debug("remote: seek \(position)")
                await self?.onSeek?(position)
            }
        ]
    }

    func updateNowPlayingInfo(with trackInfo: TrackInfo) {
        let duration: MediaDuration? = trackInfo.duration > 0 ? .finite(trackInfo.duration) : nil
        let content = MusicContent(
            id: trackInfo.title + "|" + trackInfo.artist,
            songTitle: trackInfo.title,
            artistName: trackInfo.artist,
            albumName: trackInfo.album,
            type: .audio,
            duration: duration,
            artwork: Self.makeArtwork(from: trackInfo.artworkImage)
        )
        representable.content = content
        representable.playbackSnapshot = MediaPlaybackSnapshot(
            state: trackInfo.isPaused ? .paused : .playing(rate: 1.0),
            elapsedTime: trackInfo.currentTime
        )
    }

    func clearNowPlayingInfo() {
        representable.content = nil
        representable.playbackSnapshot = MediaPlaybackSnapshot(state: .stopped)
    }

    /// Builds a NowPlaying `Artwork` whose provider closure is `@Sendable` and captures an
    /// immutable `CGImage`. Kept `nonisolated` and free of `@MainActor` capture so the
    /// framework may invoke the provider on any queue — the same off-main-callback hazard
    /// that caused the v1.0.3 artwork crash under the old `MPMediaItemArtwork` handler.
    nonisolated private static func makeArtwork(from image: NSImage?) -> Artwork? {
        guard let image,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        let sendableImage = SendableCGImage(cgImage)
        return Artwork(id: "com.ultimateytm.app.artwork") { _ in
            try ArtworkRepresentation(cgImage: sendableImage.image)
        }
    }
}

/// `CGImage` is immutable but not formally `Sendable`; wrap it so it can be captured in the
/// `@Sendable` artwork provider without a concurrency diagnostic.
private struct SendableCGImage: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
