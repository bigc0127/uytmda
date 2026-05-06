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
import Carbon

@MainActor
class AppSettings: ObservableObject {
    static let shared = AppSettings()
    
    private let defaults = UserDefaults.standard
    
    // Keys
    private enum Keys {
        static let showEqualizer = "showEqualizer"
        static let equalizerWidthOverride = "equalizerWidthOverride"
        static let showNotifications = "showNotifications"
        static let notifyOnTrackChange = "notifyOnTrackChange"
        static let miniPlayerOnTop = "miniPlayerOnTop"
        static let startWithMiniPlayer = "startWithMiniPlayer"
        static let playPauseShortcut = "playPauseShortcut"
        static let nextTrackShortcut = "nextTrackShortcut"
        static let previousTrackShortcut = "previousTrackShortcut"
        static let windowFrame = "windowFrame"
        static let miniPlayerFrame = "miniPlayerFrame"
        static let lastVolume = "lastVolume"
        static let preferredAuthMethod = "preferredAuthMethod"
        static let lastAuthenticationStatus = "lastAuthenticationStatus"
        static let lastAuthenticationDate = "lastAuthenticationDate"
    }
    
    // Visual settings
    @Published var showEqualizer: Bool {
        didSet {
            defaults.set(showEqualizer, forKey: Keys.showEqualizer)
            NotificationCenter.default.post(name: .equalizerSettingChanged, object: nil)
        }
    }

    @Published var equalizerWidthOverride: Double {
        didSet {
            defaults.set(equalizerWidthOverride, forKey: Keys.equalizerWidthOverride)
            NotificationCenter.default.post(name: .equalizerSettingChanged, object: nil)
        }
    }

    // Notification settings
    @Published var showNotifications: Bool {
        didSet { defaults.set(showNotifications, forKey: Keys.showNotifications) }
    }
    
    @Published var notifyOnTrackChange: Bool {
        didSet { defaults.set(notifyOnTrackChange, forKey: Keys.notifyOnTrackChange) }
    }
    
    // Mini player settings
    @Published var miniPlayerOnTop: Bool {
        didSet { defaults.set(miniPlayerOnTop, forKey: Keys.miniPlayerOnTop) }
    }
    
    @Published var startWithMiniPlayer: Bool {
        didSet { defaults.set(startWithMiniPlayer, forKey: Keys.startWithMiniPlayer) }
    }
    
    // Volume
    @Published var lastVolume: Float {
        didSet { defaults.set(lastVolume, forKey: Keys.lastVolume) }
    }
    
    // Authentication tracking
    @Published var preferredAuthMethod: String {
        didSet { defaults.set(preferredAuthMethod, forKey: Keys.preferredAuthMethod) }
    }
    
    @Published var lastAuthenticationStatus: String {
        didSet { defaults.set(lastAuthenticationStatus, forKey: Keys.lastAuthenticationStatus) }
    }
    
    @Published var lastAuthenticationDate: Date? {
        didSet { defaults.set(lastAuthenticationDate, forKey: Keys.lastAuthenticationDate) }
    }
    
    private init() {
        self.showEqualizer = defaults.bool(forKey: Keys.showEqualizer, default: true)
        self.equalizerWidthOverride = defaults.double(forKey: Keys.equalizerWidthOverride)
        self.showNotifications = defaults.bool(forKey: Keys.showNotifications, default: true)
        self.notifyOnTrackChange = defaults.bool(forKey: Keys.notifyOnTrackChange, default: true)
        self.miniPlayerOnTop = defaults.bool(forKey: Keys.miniPlayerOnTop, default: true)
        self.startWithMiniPlayer = defaults.bool(forKey: Keys.startWithMiniPlayer, default: false)
        self.lastVolume = defaults.float(forKey: Keys.lastVolume, default: 1.0)
        self.preferredAuthMethod = defaults.string(forKey: Keys.preferredAuthMethod) ?? "cookies-first"
        self.lastAuthenticationStatus = defaults.string(forKey: Keys.lastAuthenticationStatus) ?? "unknown"
        self.lastAuthenticationDate = defaults.object(forKey: Keys.lastAuthenticationDate) as? Date
    }
    
    // Window frame persistence
    func saveWindowFrame(_ frame: NSRect, forWindow identifier: String) {
        let key = Keys.windowFrame + "_" + identifier
        let dict: [String: CGFloat] = [
            "x": frame.origin.x,
            "y": frame.origin.y,
            "width": frame.size.width,
            "height": frame.size.height
        ]
        defaults.set(dict, forKey: key)
    }
    
    func loadWindowFrame(forWindow identifier: String) -> NSRect? {
        let key = Keys.windowFrame + "_" + identifier
        guard let dict = defaults.dictionary(forKey: key) as? [String: CGFloat],
              let x = dict["x"],
              let y = dict["y"],
              let width = dict["width"],
              let height = dict["height"] else {
            return nil
        }
        return NSRect(x: x, y: y, width: width, height: height)
    }
    
    // Keyboard shortcuts (stored as key code + modifier flags)
    struct KeyboardShortcut: Codable {
        let keyCode: Int
        let modifierFlags: UInt
        
        var displayString: String {
            var keys: [String] = []
            
            if modifierFlags & UInt(NSEvent.ModifierFlags.command.rawValue) != 0 {
                keys.append("⌘")
            }
            if modifierFlags & UInt(NSEvent.ModifierFlags.control.rawValue) != 0 {
                keys.append("⌃")
            }
            if modifierFlags & UInt(NSEvent.ModifierFlags.option.rawValue) != 0 {
                keys.append("⌥")
            }
            if modifierFlags & UInt(NSEvent.ModifierFlags.shift.rawValue) != 0 {
                keys.append("⇧")
            }
            
            // Convert key code to string
            keys.append(keyCodeToString(keyCode))
            
            return keys.joined()
        }
        
        private func keyCodeToString(_ code: Int) -> String {
            switch code {
            case kVK_Space: return "Space"
            case kVK_Return: return "↵"
            case kVK_Delete: return "⌫"
            case kVK_Escape: return "⎋"
            case kVK_Tab: return "⇥"
            case kVK_LeftArrow: return "←"
            case kVK_RightArrow: return "→"
            case kVK_UpArrow: return "↑"
            case kVK_DownArrow: return "↓"
            default:
                // Try to get the character
                let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
                let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
                
                if let data = layoutData {
                    let keyLayout = unsafeBitCast(data, to: CFData.self)
                    var deadKeyState: UInt32 = 0
                    var length = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    
                    let status = UCKeyTranslate(
                        unsafeBitCast(CFDataGetBytePtr(keyLayout), to: UnsafePointer<UCKeyboardLayout>.self),
                        UInt16(code),
                        UInt16(kUCKeyActionDisplay),
                        0,
                        UInt32(LMGetKbdType()),
                        UInt32(kUCKeyTranslateNoDeadKeysMask),
                        &deadKeyState,
                        4,
                        &length,
                        &chars
                    )
                    
                    if status == noErr && length > 0 {
                        return String(utf16CodeUnits: chars, count: length).uppercased()
                    }
                }
                return String(format: "%02X", code)
            }
        }
    }
    
    var playPauseShortcut: KeyboardShortcut {
        get {
            if let data = defaults.data(forKey: Keys.playPauseShortcut),
               let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: data) {
                return shortcut
            }
            // Default: Cmd+Shift+Space
            return KeyboardShortcut(
                keyCode: kVK_Space,
                modifierFlags: UInt(NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.shift.rawValue)
            )
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.playPauseShortcut)
            }
        }
    }
    
    var nextTrackShortcut: KeyboardShortcut {
        get {
            if let data = defaults.data(forKey: Keys.nextTrackShortcut),
               let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: data) {
                return shortcut
            }
            // Default: Cmd+Shift+→
            return KeyboardShortcut(
                keyCode: kVK_RightArrow,
                modifierFlags: UInt(NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.shift.rawValue)
            )
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.nextTrackShortcut)
            }
        }
    }
    
    var previousTrackShortcut: KeyboardShortcut {
        get {
            if let data = defaults.data(forKey: Keys.previousTrackShortcut),
               let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: data) {
                return shortcut
            }
            // Default: Cmd+Shift+←
            return KeyboardShortcut(
                keyCode: kVK_LeftArrow,
                modifierFlags: UInt(NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.shift.rawValue)
            )
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.previousTrackShortcut)
            }
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let equalizerSettingChanged = Notification.Name("equalizerSettingChanged")
}

// UserDefaults extension for cleaner default value handling
private extension UserDefaults {
    func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        if object(forKey: key) == nil {
            return defaultValue
        }
        return bool(forKey: key)
    }
    
    func float(forKey key: String, default defaultValue: Float) -> Float {
        if object(forKey: key) == nil {
            return defaultValue
        }
        return float(forKey: key)
    }
}
