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

    private func configure() {
        titlebarAppearsTransparent = true
        titleVisibility = .visible
        isMovableByWindowBackground = true
        animationBehavior = .documentWindow
        installVisualEffectBackground()
    }

    private func installVisualEffectBackground() {
        guard let contentView = contentView else { return }
        let effect = NSVisualEffectView(frame: contentView.bounds)
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        effect.autoresizingMask = [.width, .height]
        contentView.addSubview(effect, positioned: .below, relativeTo: nil)
    }

    func updateGlassMaterial(_ material: NSVisualEffectView.Material) {
        guard let effect = contentView?.subviews.compactMap({ $0 as? NSVisualEffectView }).first else { return }
        effect.material = material
    }

    func updateBlendingMode(_ mode: NSVisualEffectView.BlendingMode) {
        guard let effect = contentView?.subviews.compactMap({ $0 as? NSVisualEffectView }).first else { return }
        effect.blendingMode = mode
    }
}
