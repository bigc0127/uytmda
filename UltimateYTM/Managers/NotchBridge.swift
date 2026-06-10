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

// MARK: - NotchBridge
//
// Implements the UltimateYTM ↔ NotchNest DistributedNotification contract:
//   A) Broadcasts com.ultimateytm.app.playbackUpdate with contract-A userInfo.
//   B) Subscribes to com.ultimateytm.app.remoteCommand and drives WebViewManager.
//   C) Subscribes to com.ultimateytm.app.requestState and re-broadcasts current state.

@MainActor
final class NotchBridge {
    static let shared = NotchBridge()

    // Set by MainWindowController after WebViewManager is ready.
    weak var webViewManager: WebViewManager?

    private let dnc = DistributedNotificationCenter.default()
    private var lastBroadcastArtworkURL: String? = nil
    private var cachedArtworkPath: String = ""

    private nonisolated static let updateName  = Notification.Name("com.ultimateytm.app.playbackUpdate")
    private nonisolated static let commandName = Notification.Name("com.ultimateytm.app.remoteCommand")
    private nonisolated static let requestName = Notification.Name("com.ultimateytm.app.requestState")
    private static let artworkFile = NSTemporaryDirectory() + "ultimateytm-artwork.png"

    private init() {
        subscribeToIncoming()
    }

    deinit {
        dnc.removeObserver(self, name: Self.commandName, object: nil)
        dnc.removeObserver(self, name: Self.requestName, object: nil)
    }

    // MARK: - A. Broadcast playback state

    /// Called from the track-state chokepoint (MainWindowController delegate).
    func broadcast(trackInfo: TrackInfo) {
        // Write artwork PNG if the artwork has changed.
        updateArtworkFileIfNeeded(trackInfo: trackInfo)

        let userInfo: [String: String] = [
            "title":       trackInfo.title,
            "artist":      trackInfo.artist,
            "album":       trackInfo.album,
            "duration":    String(trackInfo.duration),
            "elapsed":     String(trackInfo.currentTime),
            "isPlaying":   trackInfo.isPaused ? "0" : "1",
            "artworkPath": cachedArtworkPath,
            "trackID":     extractTrackID(from: trackInfo.artworkURL),
        ]

        dnc.postNotificationName(
            Self.updateName,
            object: nil,
            userInfo: userInfo as [AnyHashable: Any],
            deliverImmediately: true
        )
    }

    // MARK: - Artwork helper

    private func updateArtworkFileIfNeeded(trackInfo: TrackInfo) {
        let newURL = trackInfo.artworkURL ?? ""
        // Artwork URL changed → try to write the image if we have it.
        if newURL != lastBroadcastArtworkURL {
            lastBroadcastArtworkURL = newURL
            if let image = trackInfo.artworkImage {
                if writeArtworkPNG(image: image) {
                    cachedArtworkPath = Self.artworkFile
                } else {
                    cachedArtworkPath = ""
                }
            } else if newURL.isEmpty {
                cachedArtworkPath = ""
            }
            // If artworkImage is nil but URL is non-empty, keep the previous
            // cached path so the companion doesn't lose art while it loads.
        } else if trackInfo.artworkImage != nil && cachedArtworkPath.isEmpty {
            // Same URL but image just arrived (async download completed).
            if let image = trackInfo.artworkImage, writeArtworkPNG(image: image) {
                cachedArtworkPath = Self.artworkFile
            }
        }
    }

    private func writeArtworkPNG(image: NSImage) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return false
        }
        do {
            try png.write(to: URL(fileURLWithPath: Self.artworkFile), options: .atomic)
            return true
        } catch {
            print("[NotchBridge] Failed to write artwork PNG: \(error)")
            return false
        }
    }

    // MARK: - trackID extraction

    /// YouTube thumbnail URLs of the form .../vi/<videoId>/... let us extract
    /// a stable video ID. Falls back to "" when format is unrecognised.
    private func extractTrackID(from artworkURL: String?) -> String {
        guard let url = artworkURL, !url.isEmpty else { return "" }
        // e.g. https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg
        if let range = url.range(of: "/vi/") {
            let after = url[range.upperBound...]
            if let slash = after.firstIndex(of: "/") {
                return String(after[after.startIndex..<slash])
            }
        }
        return ""
    }

    // MARK: - B & C. Subscribe to incoming notifications

    private func subscribeToIncoming() {
        dnc.addObserver(
            self,
            selector: #selector(handleRemoteCommand(_:)),
            name: Self.commandName,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        dnc.addObserver(
            self,
            selector: #selector(handleRequestState(_:)),
            name: Self.requestName,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    // MARK: - B. Remote command handler

    @objc private func handleRemoteCommand(_ notification: Notification) {
        guard let info = notification.userInfo,
              let command = info["command"] as? String else { return }
        let value = info["value"] as? String ?? ""

        Task { @MainActor [weak self] in
            guard let wvm = self?.webViewManager else { return }
            switch command {
            case "playpause":
                await wvm.playPause()
            case "play":
                // Only play if currently paused.
                if wvm.currentTrackInfo.isPaused {
                    await wvm.playPause()
                }
            case "pause":
                // Only pause if currently playing.
                if !wvm.currentTrackInfo.isPaused {
                    await wvm.playPause()
                }
            case "next":
                await wvm.nextTrack()
            case "previous":
                await wvm.previousTrack()
            case "seek":
                if let seconds = Double(value) {
                    await wvm.seekTo(time: seconds)
                }
            default:
                print("[NotchBridge] Unknown remote command: \(command)")
            }
        }
    }

    // MARK: - C. State request handler

    @objc private func handleRequestState(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Re-broadcast the current known state immediately.
            if let wvm = self.webViewManager {
                self.broadcast(trackInfo: wvm.currentTrackInfo)
            }
        }
    }
}
