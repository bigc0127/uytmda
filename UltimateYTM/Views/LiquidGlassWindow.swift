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

class LiquidGlassWindow: NSWindow {
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        var modernStyle = style
        modernStyle.insert(.fullSizeContentView)
        super.init(contentRect: contentRect, styleMask: modernStyle, backing: backingStoreType, defer: flag)
        configure()
    }

    private var glassView: NSGlassEffectView?

    private func configure() {
        titlebarAppearsTransparent = true
        titleVisibility = .visible
        isMovableByWindowBackground = true
        animationBehavior = .documentWindow
        installGlassBackground()
    }

    /// Installs a macOS 27 Liquid Glass background (`NSGlassEffectView`) behind the window
    /// content. It shows through the transparent titlebar and any translucent regions, with
    /// interactive glass feedback enabled. Replaces the legacy `NSVisualEffectView` backing.
    private func installGlassBackground() {
        guard let contentView = contentView else { return }
        let glass = NSGlassEffectView(frame: contentView.bounds)
        glass.style = .regular
        glass.cornerRadius = 0
        glass.effectIsInteractive = true
        glass.autoresizingMask = [.width, .height]
        contentView.addSubview(glass, positioned: .below, relativeTo: nil)
        glassView = glass
    }

    /// Tints the glass toward a color (nil = untinted).
    func setGlassTint(_ color: NSColor?) {
        glassView?.tintColor = color
    }

    /// Switches between the standard (`.regular`) and `.clear` glass styles.
    func setGlassStyle(_ style: NSGlassEffectView.Style) {
        glassView?.style = style
    }
}
