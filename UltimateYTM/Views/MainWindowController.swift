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
import ApplicationServices
import WebKit

@MainActor
class MainWindowController: NSWindowController {
    private var webViewManager: WebViewManager!
    private var currentTrackInfo: TrackInfo = .empty
    var onAuthenticationDetected: ((Bool) -> Void)?

    var playerWebView: WKWebView? { webViewManager?.webView }

    private var dockEqualizerWindow: NSWindow?
    private var dockEqualizerView: RainbowEqualizerView?

    convenience init() {
        let window = LiquidGlassWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Ultimate YTM"
        window.minSize = NSSize(width: 800, height: 600)
        window.center()
        window.setFrameAutosaveName("MainWindow")
        self.init(window: window)
        windowFrameAutosaveName = "MainWindow"
        setup()
    }

    private func setup() {
        installWebView()
        installDockEqualizerOverlay()
        startAudioCapture()
        observeSettings()
        restoreWindowFrame()
        window?.delegate = self
    }

    // MARK: - WebView

    private func installWebView() {
        guard let window = window,
              let contentView = window.contentView,
              let layoutGuide = window.contentLayoutGuide as? NSLayoutGuide else { return }

        webViewManager = WebViewManager()
        webViewManager.delegate = self
        guard let webView = webViewManager.webView else { return }

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.setValue(false, forKey: "drawsBackground")
        contentView.addSubview(webView)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: layoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    // MARK: - Equalizer overlay

    private func startAudioCapture() {
        Task { await AudioCaptureManager.shared.startCapture() }
        AudioCaptureManager.shared.onAudioLevelsUpdated = { [weak self] levels in
            self?.dockEqualizerView?.applyLevels(levels)
        }
    }

    private var dockTrackingTimer: Timer?

    private func observeSettings() {
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: .equalizerSettingChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func screenParametersChanged() {
        Task { @MainActor in updateDockEqualizerFrame() }
    }

    private func installDockEqualizerOverlay() {
        guard AppSettings.shared.showEqualizer else {
            tearDownDockEqualizerOverlay()
            return
        }

        guard let dockFrame = dockOverlayFrame() else {
            tearDownDockEqualizerOverlay()
            return
        }

        let isPillShaped = isDockPillFrame(dockFrame, screen: window?.screen ?? NSScreen.main!)
        let cornerRadius: CGFloat = isPillShaped ? min(dockFrame.height / 2, 24) : 0

        if let overlay = dockEqualizerWindow {
            overlay.setFrame(dockFrame, display: true)
            overlay.contentView?.layer?.cornerRadius = cornerRadius
            overlay.orderFrontRegardless()
            startDockTracking()
            return
        }

        let overlay = NSWindow(contentRect: dockFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        overlay.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)))

        if let contentView = overlay.contentView {
            contentView.wantsLayer = true
            contentView.layer?.cornerRadius = cornerRadius
            contentView.layer?.cornerCurve = .continuous
            contentView.layer?.masksToBounds = true

            let eq = RainbowEqualizerView(frame: contentView.bounds)
            eq.autoresizingMask = [.width, .height]
            contentView.addSubview(eq)
            dockEqualizerView = eq
        }

        overlay.orderFrontRegardless()
        dockEqualizerWindow = overlay
        startDockTracking()
    }

    private func tearDownDockEqualizerOverlay() {
        dockTrackingTimer?.invalidate()
        dockTrackingTimer = nil
        dockEqualizerWindow?.orderOut(nil)
        dockEqualizerWindow = nil
        dockEqualizerView = nil
    }

    private func startDockTracking() {
        dockTrackingTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateDockEqualizerFrame() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dockTrackingTimer = timer
    }

    private func updateDockEqualizerFrame() {
        guard AppSettings.shared.showEqualizer else { return }
        guard let frame = dockOverlayFrame() else {
            dockEqualizerWindow?.orderOut(nil)
            return
        }
        if dockEqualizerWindow?.isVisible == false {
            dockEqualizerWindow?.orderFrontRegardless()
        }
        if dockEqualizerWindow?.frame != frame {
            dockEqualizerWindow?.setFrame(frame, display: true)
        }
    }

    /// Returns the frame, in NSScreen coordinates, covering the visible Dock
    /// pill. Tries Accessibility first (exact); otherwise estimates the pill
    /// width from `com.apple.dock` defaults — works without any permission.
    private func dockOverlayFrame() -> NSRect? {
        guard let screen = window?.screen ?? NSScreen.main else { return nil }
        let dockHeight = screen.visibleFrame.minY - screen.frame.minY
        guard dockHeight > 1 else { return nil }

        let override = AppSettings.shared.equalizerWidthOverride
        if override > 0 {
            let width = min(CGFloat(override), screen.frame.width)
            let pillHeight = dockHeight - 6
            let x = screen.frame.minX + (screen.frame.width - width) / 2
            let y = screen.frame.minY + (dockHeight - pillHeight) / 2
            return NSRect(x: x, y: y, width: width, height: pillHeight)
        }

        if let exact = dockListFrameViaAccessibility(on: screen) {
            return exact
        }
        if let estimated = dockFrameFromDefaults(on: screen, dockHeight: dockHeight) {
            return estimated
        }
        return NSRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: dockHeight)
    }

    /// Estimate the visible Dock pill bounds using `com.apple.dock` defaults.
    /// The Dock pill is centered horizontally; its width depends on tilesize
    /// and the number of items. Macos has no public API for the exact
    /// rendered geometry, so this estimate is calibrated against typical
    /// macOS 26 layouts.
    private func dockFrameFromDefaults(on screen: NSScreen, dockHeight: CGFloat) -> NSRect? {
        guard let plist = readDockPlist(), !plist.isEmpty else { return nil }
        guard (plist["orientation"] as? String ?? "bottom") == "bottom" else { return nil }
        guard let tilesize = (plist["tilesize"] as? Double).flatMap({ CGFloat($0) }), tilesize > 0 else { return nil }

        let persistentApps = (plist["persistent-apps"] as? [Any])?.count ?? 0
        let persistentOthers = (plist["persistent-others"] as? [Any])?.count ?? 0
        let showRecents = (plist["show-recents"] as? Bool) ?? true
        let recentApps = showRecents ? ((plist["recent-apps"] as? [Any])?.count ?? 0) : 0
        let totalItems = persistentApps + persistentOthers + recentApps + 1
        guard totalItems > 1 else { return nil }

        let pillHeight = dockHeight - 6
        let estimatedWidth = tilesize * CGFloat(totalItems) + 3 * CGFloat(totalItems - 1) + 32
        let width = min(estimatedWidth, screen.frame.width - 80)
        let x = screen.frame.minX + (screen.frame.width - width) / 2
        let y = screen.frame.minY + (dockHeight - pillHeight) / 2
        return NSRect(x: x, y: y, width: width, height: pillHeight)
    }

    private func readDockPlist() -> [String: Any]? {
        let path = NSHomeDirectory() + "/Library/Preferences/com.apple.dock.plist"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           !plist.isEmpty {
            return plist
        }
        return shellReadDockPlist()
    }

    private func shellReadDockPlist() -> [String: Any]? {
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "/usr/bin/defaults export com.apple.dock -"]
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard !data.isEmpty,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              !plist.isEmpty else { return nil }
        return plist
    }

    private func isDockPillFrame(_ frame: NSRect, screen: NSScreen) -> Bool {
        // A pill is narrower than the full screen width; the full-width
        // fallback isn't a pill so it shouldn't get rounded corners.
        return frame.width < screen.frame.width - 40
    }

private func dockListFrameViaAccessibility(on screen: NSScreen) -> NSRect? {
        guard AXIsProcessTrusted() else { return nil }
        guard let primary = NSScreen.screens.first else { return nil }
        guard let dockPID = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.dock" })?.processIdentifier else { return nil }

        let dockApp = AXUIElementCreateApplication(dockPID)
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(dockApp, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }

        for child in children {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            guard (roleRef as? String) == kAXListRole else { continue }

            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &posRef)
            AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &sizeRef)
            guard let posVal = posRef, let sizeVal = sizeRef else { continue }

            var origin = CGPoint.zero
            var size = CGSize.zero
            AXValueGetValue(posVal as! AXValue, .cgPoint, &origin)
            AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
            guard size.width > 0, size.height > 0 else { continue }

            let nsY = primary.frame.maxY - origin.y - size.height
            return NSRect(x: origin.x, y: nsY, width: size.width, height: size.height)
        }
        return nil
    }

    @objc private func settingsChanged() {
        Task { @MainActor in
            installDockEqualizerOverlay()
            if AppSettings.shared.showEqualizer {
                dockEqualizerView?.setPlaying(currentTrackInfo.isValid && !currentTrackInfo.isPaused)
            }
        }
    }

    // MARK: - Window frame

    private func restoreWindowFrame() {
        if let frame = AppSettings.shared.loadWindowFrame(forWindow: "main") {
            window?.setFrame(frame, display: true)
        }
    }

    private func saveWindowFrame() {
        if let frame = window?.frame {
            AppSettings.shared.saveWindowFrame(frame, forWindow: "main")
        }
    }
}

// MARK: - WebViewManagerDelegate

extension MainWindowController: WebViewManagerDelegate {
    func webViewManager(_ manager: WebViewManager, didUpdateTrackInfo trackInfo: TrackInfo) {
        let previous = currentTrackInfo
        currentTrackInfo = trackInfo

        if trackInfo.title != previous.title {
            NotificationManager.shared.showTrackChangeNotification(trackInfo: trackInfo)
        }

        window?.title = trackInfo.isValid ? "\(trackInfo.title) — \(trackInfo.artist)" : "Ultimate YTM"
        NotificationCenter.default.post(name: .trackInfoUpdated, object: trackInfo)
        dockEqualizerView?.setPlaying(trackInfo.isValid && !trackInfo.isPaused)
    }

    func webViewManagerDidLoad(_ manager: WebViewManager) {
        Task {
            let isAuthed = await manager.evaluateAuthState()
            onAuthenticationDetected?(isAuthed)
        }
    }
}

// MARK: - NSWindowDelegate

extension MainWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) { saveWindowFrame() }
    func windowWillMiniaturize(_ notification: Notification) { saveWindowFrame() }
}

// MARK: - Notification Names

extension Notification.Name {
    static let toggleMiniPlayer = Notification.Name("toggleMiniPlayer")
    static let showPreferences = Notification.Name("showPreferences")
    static let trackInfoUpdated = Notification.Name("trackInfoUpdated")
}
