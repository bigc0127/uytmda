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
class KeyboardShortcutManager {
    static let shared = KeyboardShortcutManager()
    
    var onPlayPause: (() async -> Void)?
    var onNext: (() async -> Void)?
    var onPrevious: (() async -> Void)?
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    
    private init() {}
    
    func startMonitoring() {
        guard eventTap == nil else { return }
        
        let eventMask = (1 << CGEventType.keyDown.rawValue)
        
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { proxy, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<KeyboardShortcutManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("Failed to create event tap")
            return
        }
        
        self.eventTap = eventTap
        
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        
        self.runLoopSource = runLoopSource
    }
    
    func stopMonitoring() {
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
        
        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
    }
    
    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent> {
        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }
        
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let modifierFlags = UInt(flags.rawValue)
        
        let settings = AppSettings.shared
        
        // Check play/pause shortcut
        if keyCode == settings.playPauseShortcut.keyCode &&
            modifierFlags & UInt(settings.playPauseShortcut.modifierFlags) == UInt(settings.playPauseShortcut.modifierFlags) {
            Task { @MainActor in
                await self.onPlayPause?()
            }
            // Consume the event
            return Unmanaged.passUnretained(event) // We could return nil to consume, but that causes issues
        }
        
        // Check next track shortcut
        if keyCode == settings.nextTrackShortcut.keyCode &&
            modifierFlags & UInt(settings.nextTrackShortcut.modifierFlags) == UInt(settings.nextTrackShortcut.modifierFlags) {
            Task { @MainActor in
                await self.onNext?()
            }
            return Unmanaged.passUnretained(event)
        }
        
        // Check previous track shortcut
        if keyCode == settings.previousTrackShortcut.keyCode &&
            modifierFlags & UInt(settings.previousTrackShortcut.modifierFlags) == UInt(settings.previousTrackShortcut.modifierFlags) {
            Task { @MainActor in
                await self.onPrevious?()
            }
            return Unmanaged.passUnretained(event)
        }
        
        return Unmanaged.passUnretained(event)
    }
}
