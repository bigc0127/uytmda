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

import CoreGraphics
import Foundation

/// Estimates the visible Dock pill width from Dock preferences plus the live set of
/// running apps — the no-permission fallback when Accessibility isn't granted.
/// Calibrated on macOS 27 beta 4 (rest state; magnification only affects hover, so it
/// is ignored): item pitch = tilesize + 4, separator = 27 pt, edge padding = 8 pt/side.
enum DockPillEstimator {

    /// Pure geometry: pill width for a tile size, icon-item count and separator count.
    static func pillWidth(tilesize: CGFloat, itemCount: Int, separatorCount: Int) -> CGFloat {
        guard tilesize > 0, itemCount > 0 else { return 0 }
        return (tilesize + 4) * CGFloat(itemCount) + 27 * CGFloat(separatorCount) + 16
    }

    /// Derives icon-item and separator counts from Dock plist content plus running apps.
    /// - persistentAppIDs: bundle IDs pinned in the Dock (plist `persistent-apps`)
    /// - otherItemCount: plist `persistent-others` count (folders/stacks)
    /// - recentAppIDs: plist `recent-apps` bundle IDs; pass [] when show-recents is off
    /// - runningAppIDs: bundle IDs of running apps with `.regular` activation policy
    static func counts(persistentAppIDs: [String],
                       otherItemCount: Int,
                       recentAppIDs: [String],
                       runningAppIDs: [String]) -> (items: Int, separators: Int) {
        let finderID = "com.apple.finder"
        let persistent = Set(persistentAppIDs)
        // Finder always occupies the leading slot whether or not it's pinned.
        let appSection = persistent.subtracting([finderID]).count + 1
        // Middle section: recents plus running-but-unpinned apps, deduped.
        let middle = Set(recentAppIDs).union(runningAppIDs)
            .subtracting(persistent)
            .subtracting([finderID])
            .count
        // Trailing section: folders/stacks plus Trash (always visible).
        let otherSection = otherItemCount + 1
        let separators = (middle > 0 ? 1 : 0) + 1
        return (appSection + middle + otherSection, separators)
    }
}
