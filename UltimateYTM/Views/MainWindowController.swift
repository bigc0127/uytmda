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
        NotchBridge.shared.webViewManager = webViewManager

        // Wire MediaPlayerManager remote-command callbacks to WebViewManager.
        let mpm = MediaPlayerManager.shared
        mpm.onPlayPause = { [weak self] in await self?.webViewManager.playPause() }
        mpm.onNext      = { [weak self] in await self?.webViewManager.nextTrack() }
        mpm.onPrevious  = { [weak self] in await self?.webViewManager.previousTrack() }
        mpm.onSeek      = { [weak self] t in await self?.webViewManager.seekTo(time: t) }

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
        // macOS 27 MusicUnderstanding: perceptual loudness modulates the rainbow brightness.
        MusicAnalysisManager.shared.onEnergyUpdated = { [weak self] energy in
            self?.dockEqualizerView?.applyEnergy(energy)
        }
    }

    /// Toggles the dock equalizer's play state and starts/stops MusicUnderstanding loudness
    /// analysis in lockstep, so on-device analysis only runs while music is actually playing.
    private func updateEqualizerPlayState(_ playing: Bool) {
        dockEqualizerView?.setPlaying(playing)
        if playing && dockEqualizerView != nil {
            MusicAnalysisManager.shared.start()
        } else {
            MusicAnalysisManager.shared.stop()
        }
    }

    private var dockTrackingTimer: Timer?
    private var dockBurstTimer: Timer?
    private var dockBurstTicks = 0

    private func observeSettings() {
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: .equalizerSettingChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let wsCenter = NSWorkspace.shared.notificationCenter
        wsCenter.addObserver(self, selector: #selector(runningAppsChanged), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        wsCenter.addObserver(self, selector: #selector(runningAppsChanged), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }

    @objc private func runningAppsChanged() {
        Task { @MainActor in self.burstTrackDockResize() }
    }

    /// Follow the Dock's own grow/shrink animation after an app launches or quits:
    /// re-read the pill frame at 10 Hz for 2 s, then fall back to the 1 s steady poll.
    private func burstTrackDockResize() {
        dockBurstTimer?.invalidate()
        dockBurstTicks = 0
        // The timer param stays outside the isolated closure: touching it inside trips
        // Swift 6 region isolation (task-isolated value captured by @MainActor closure).
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] t in
            let done = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return true }
                self.dockBurstTicks += 1
                self.updateDockEqualizerFrame()
                if self.dockBurstTicks >= 20 {
                    self.dockBurstTimer = nil
                    return true
                }
                return false
            }
            if done { t.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dockBurstTimer = timer
    }

    @objc private func screenParametersChanged() {
        Task { @MainActor in updateDockEqualizerFrame() }
    }

    private func installDockEqualizerOverlay() {
        guard AppSettings.shared.showEqualizer else {
            tearDownDockEqualizerOverlay()
            return
        }

        requestAccessibilityIfNeeded()

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
        dockBurstTimer?.invalidate()
        dockBurstTimer = nil
        dockEqualizerWindow?.orderOut(nil)
        dockEqualizerWindow = nil
        dockEqualizerView = nil
        if let activity = dockTrackingActivity {
            ProcessInfo.processInfo.endActivity(activity)
            dockTrackingActivity = nil
        }
    }

    private var dockTrackingActivity: NSObjectProtocol?

    private func startDockTracking() {
        // App Nap freezes our timers when the main window is minimized/occluded, so the
        // overlay stops tracking the Dock until the app regains focus. Declare an
        // activity while the overlay lives (allows idle system sleep, only blocks nap).
        if dockTrackingActivity == nil {
            dockTrackingActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Dock equalizer tracks Dock size"
            )
        }
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
            if let screen = window?.screen ?? NSScreen.main {
                let isPill = isDockPillFrame(frame, screen: screen)
                dockEqualizerWindow?.contentView?.layer?.cornerRadius = isPill ? min(frame.height / 2, 24) : 0
            }
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

    /// Estimate the visible Dock pill bounds from `com.apple.dock` defaults plus the
    /// live set of running apps. macOS has no public API for the rendered geometry;
    /// constants are calibrated against macOS 27 beta 4 (see DockPillEstimator).
    private func dockFrameFromDefaults(on screen: NSScreen, dockHeight: CGFloat) -> NSRect? {
        guard let plist = readDockPlist(), !plist.isEmpty else { return nil }
        guard (plist["orientation"] as? String ?? "bottom") == "bottom" else { return nil }
        guard let tilesize = (plist["tilesize"] as? Double).flatMap({ CGFloat($0) }), tilesize > 0 else { return nil }

        let persistentIDs = Self.bundleIDs(inTiles: plist["persistent-apps"])
        let otherCount = (plist["persistent-others"] as? [Any])?.count ?? 0
        let showRecents = (plist["show-recents"] as? Bool) ?? true
        let recentIDs = showRecents ? Self.bundleIDs(inTiles: plist["recent-apps"]) : []
        let runningIDs = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier)

        let (items, separators) = DockPillEstimator.counts(
            persistentAppIDs: persistentIDs,
            otherItemCount: otherCount,
            recentAppIDs: recentIDs,
            runningAppIDs: runningIDs)
        let estimatedWidth = DockPillEstimator.pillWidth(
            tilesize: tilesize, itemCount: items, separatorCount: separators)
        guard estimatedWidth > 0 else { return nil }

        let pillHeight = dockHeight - 6
        let width = min(estimatedWidth, screen.frame.width - 80)
        let x = screen.frame.minX + (screen.frame.width - width) / 2
        let y = screen.frame.minY + (dockHeight - pillHeight) / 2
        return NSRect(x: x, y: y, width: width, height: pillHeight)
    }

    private static func bundleIDs(inTiles value: Any?) -> [String] {
        guard let tiles = value as? [[String: Any]] else { return [] }
        return tiles.compactMap {
            ($0["tile-data"] as? [String: Any])?["bundle-identifier"] as? String
        }
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

    /// One-time system prompt for Accessibility so Auto width can read the exact Dock
    /// pill frame. The persisted flag means a decline is never nagged about again; if
    /// the user grants later in System Settings, the 1 s tracking timer picks it up.
    private func requestAccessibilityIfNeeded() {
        guard AppSettings.shared.equalizerWidthOverride == 0,
              !AXIsProcessTrusted(),
              !AppSettings.shared.didPromptForAccessibility else { return }
        AppSettings.shared.didPromptForAccessibility = true
        // Literal key: the kAXTrustedCheckOptionPrompt global is mutable state and
        // trips Swift 6 strict concurrency when referenced from an actor.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
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
                updateEqualizerPlayState(currentTrackInfo.isValid && !currentTrackInfo.isPaused)
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

        // Keep the ~1s polling timer running only while playing (contract requirement).
        if trackInfo.isPaused {
            manager.stopTrackInfoPolling()
        } else if previous.isPaused && !trackInfo.isPaused {
            manager.startTrackInfoPolling()
        }

        // Update system Now Playing and broadcast to companion apps.
        MediaPlayerManager.shared.updateNowPlayingInfo(with: trackInfo)
        NotchBridge.shared.broadcast(trackInfo: trackInfo)

        window?.title = trackInfo.isValid ? "\(trackInfo.title) — \(trackInfo.artist)" : "Ultimate YTM"
        NotificationCenter.default.post(name: .trackInfoUpdated, object: trackInfo)
        updateEqualizerPlayState(trackInfo.isValid && !trackInfo.isPaused)
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
