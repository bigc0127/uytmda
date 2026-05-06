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
import MediaPlayer
import AppKit

@MainActor
class MediaPlayerManager: NSObject {
    static let shared = MediaPlayerManager()
    
    private var commandCenter: MPRemoteCommandCenter {
        MPRemoteCommandCenter.shared()
    }
    
    private var nowPlayingInfo: MPNowPlayingInfoCenter {
        MPNowPlayingInfoCenter.default()
    }
    
    var onPlayPause: (() async -> Void)?
    var onNext: (() async -> Void)?
    var onPrevious: (() async -> Void)?
    var onSeek: ((TimeInterval) async -> Void)?
    
    private override init() {
        super.init()
        setupRemoteCommandCenter()
    }
    
    private func setupRemoteCommandCenter() {
        // Play command
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] event in
            Task { @MainActor in
                await self?.onPlayPause?()
            }
            return .success
        }
        
        // Pause command
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] event in
            Task { @MainActor in
                await self?.onPlayPause?()
            }
            return .success
        }
        
        // Toggle play/pause
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] event in
            Task { @MainActor in
                await self?.onPlayPause?()
            }
            return .success
        }
        
        // Next track
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] event in
            Task { @MainActor in
                await self?.onNext?()
            }
            return .success
        }
        
        // Previous track
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] event in
            Task { @MainActor in
                await self?.onPrevious?()
            }
            return .success
        }
        
        // Seek commands
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in
                await self?.onSeek?(event.positionTime)
            }
            return .success
        }
    }
    
    func updateNowPlayingInfo(with trackInfo: TrackInfo) {
        var info: [String: Any] = [:]
        
        info[MPMediaItemPropertyTitle] = trackInfo.title
        info[MPMediaItemPropertyArtist] = trackInfo.artist
        info[MPMediaItemPropertyAlbumTitle] = trackInfo.album
        info[MPMediaItemPropertyPlaybackDuration] = trackInfo.duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = trackInfo.currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = trackInfo.isPaused ? 0.0 : 1.0
        
        // Set artwork if available
        if let artworkImage = trackInfo.artworkImage {
            // Ensure artwork has a valid size
            let artworkSize = artworkImage.size.width > 0 && artworkImage.size.height > 0 
                ? artworkImage.size 
                : NSSize(width: 512, height: 512)
            
            let artwork = MPMediaItemArtwork(boundsSize: artworkSize) { requestedSize in
                // Return the original image or resize if needed
                if requestedSize == artworkImage.size {
                    return artworkImage
                }
                
                // Resize image to requested size
                let resizedImage = NSImage(size: requestedSize)
                resizedImage.lockFocus()
                artworkImage.draw(in: NSRect(origin: .zero, size: requestedSize),
                                from: NSRect(origin: .zero, size: artworkImage.size),
                                operation: .copy,
                                fraction: 1.0)
                resizedImage.unlockFocus()
                return resizedImage
            }
            info[MPMediaItemPropertyArtwork] = artwork
        }
        
        nowPlayingInfo.nowPlayingInfo = info
    }
    
    func clearNowPlayingInfo() {
        nowPlayingInfo.nowPlayingInfo = nil
    }
}
