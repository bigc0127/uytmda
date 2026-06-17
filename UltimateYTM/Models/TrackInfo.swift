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

struct TrackInfo: Equatable, Codable {
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let currentTime: TimeInterval
    let artworkURL: String?
    let isPaused: Bool
    let isShuffled: Bool
    let repeatMode: String
    let rating: String      // "" | "up" | "down"
    let inLibrary: Bool

    var artworkImage: NSImage?

    enum CodingKeys: String, CodingKey {
        case title, artist, album, duration, currentTime, artworkURL, isPaused, isShuffled, repeatMode, rating, inLibrary
    }
    
    static var empty: TrackInfo {
        TrackInfo(
            title: "",
            artist: "",
            album: "",
            duration: 0,
            currentTime: 0,
            artworkURL: nil,
            isPaused: true,
            isShuffled: false,
            repeatMode: "NONE",
            rating: "",
            inLibrary: false,
            artworkImage: nil
        )
    }
    
    var isValid: Bool {
        !title.isEmpty && !artist.isEmpty
    }
    
    var formattedDuration: String {
        formatTime(duration)
    }
    
    var formattedCurrentTime: String {
        formatTime(currentTime)
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
