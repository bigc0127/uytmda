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

import Cocoa
import WebKit

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController!
    private var miniPlayerController: MiniPlayerController?
    private var preferencesWindowController: PreferencesWindowController?

    // MARK: - Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installMainMenu()
        // MUST run before any WKWebView is created so WebKit finds the cookie
        // jar in place when it initializes the data store.
        CookieBackupManager.shared.restoreIfNeeded()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        mainWindowController = MainWindowController()
        mainWindowController.onAuthenticationDetected = { isAuthenticated in
            if !isAuthenticated {
                NSLog("ℹ️ User needs to sign in manually")
            }
        }
        mainWindowController.showWindow(nil)
        mainWindowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        attemptAutoSignIn()
        registerNotificationObservers()
        UpdateManager.shared.startAutoCheckIfEnabled()
        CookieBackupManager.shared.snapshot()
        CookieBackupManager.shared.startPeriodicSnapshots()
    }

    func applicationWillTerminate(_ notification: Notification) {
        CookieBackupManager.shared.snapshot()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            mainWindowController?.showWindow(nil)
            mainWindowController?.window?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Main Window", action: #selector(showMainWindow), keyEquivalent: "")
        menu.addItem(withTitle: "Toggle Mini Player", action: #selector(toggleMiniPlayer), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Play / Pause", action: #selector(playPauseAction), keyEquivalent: "")
        menu.addItem(withTitle: "Next Track", action: #selector(nextTrackAction), keyEquivalent: "")
        menu.addItem(withTitle: "Previous Track", action: #selector(previousTrackAction), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        return menu
    }

    // MARK: - Menu

    private func installMainMenu() {
        let mainMenu = NSMenu()

        mainMenu.addItem(buildAppMenuItem())
        mainMenu.addItem(buildFileMenuItem())
        mainMenu.addItem(buildEditMenuItem())
        mainMenu.addItem(buildViewMenuItem())
        mainMenu.addItem(buildPlaybackMenuItem())

        let windowMenuItem = buildWindowMenuItem()
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenuItem.submenu

        mainMenu.addItem(buildHelpMenuItem())

        NSApp.mainMenu = mainMenu
    }

    private func buildAppMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu()
        let appName = ProcessInfo.processInfo.processName

        menu.addItem(NSMenuItem(title: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        menu.addItem(.separator())

        let prefsItem = NSMenuItem(title: "Settings…", action: #selector(showPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)

        let updatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdatesAction), keyEquivalent: "")
        updatesItem.target = self
        menu.addItem(updatesItem)
        menu.addItem(.separator())

        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        menu.addItem(servicesItem)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)
        menu.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        item.submenu = menu
        return item
    }

    private func buildFileMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "File")

        let close = NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        menu.addItem(close)

        let reload = NSMenuItem(title: "Reload YouTube Music", action: #selector(reloadYouTubeMusic), keyEquivalent: "r")
        reload.target = self
        menu.addItem(reload)

        item.submenu = menu
        return item
    }

    private func buildEditMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")

        menu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        menu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        menu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        menu.addItem(NSMenuItem(title: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        item.submenu = menu
        return item
    }

    private func buildViewMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "View")

        let mini = NSMenuItem(title: "Toggle Mini Player", action: #selector(toggleMiniPlayer), keyEquivalent: "m")
        mini.keyEquivalentModifierMask = [.command, .shift]
        mini.target = self
        menu.addItem(mini)
        menu.addItem(.separator())

        let fs = NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        menu.addItem(fs)

        item.submenu = menu
        return item
    }

    private func buildPlaybackMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Playback")

        let playPause = NSMenuItem(title: "Play / Pause", action: #selector(playPauseAction), keyEquivalent: " ")
        playPause.keyEquivalentModifierMask = [.command, .shift]
        playPause.target = self
        menu.addItem(playPause)

        let next = NSMenuItem(title: "Next Track", action: #selector(nextTrackAction), keyEquivalent: String(UnicodeScalar(NSRightArrowFunctionKey)!))
        next.keyEquivalentModifierMask = [.command, .shift]
        next.target = self
        menu.addItem(next)

        let prev = NSMenuItem(title: "Previous Track", action: #selector(previousTrackAction), keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!))
        prev.keyEquivalentModifierMask = [.command, .shift]
        prev.target = self
        menu.addItem(prev)

        menu.addItem(.separator())

        let shuffle = NSMenuItem(title: "Toggle Shuffle", action: #selector(toggleShuffleAction), keyEquivalent: "s")
        shuffle.keyEquivalentModifierMask = [.command, .shift]
        shuffle.target = self
        menu.addItem(shuffle)

        let repeatItem = NSMenuItem(title: "Toggle Repeat", action: #selector(toggleRepeatAction), keyEquivalent: "r")
        repeatItem.keyEquivalentModifierMask = [.command, .shift]
        repeatItem.target = self
        menu.addItem(repeatItem)

        item.submenu = menu
        return item
    }

    private func buildWindowMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Window")

        menu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        menu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))

        item.submenu = menu
        return item
    }

    private func buildHelpMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Help")

        let appName = ProcessInfo.processInfo.processName
        let help = NSMenuItem(title: "\(appName) Help", action: #selector(NSApplication.showHelp(_:)), keyEquivalent: "?")
        menu.addItem(help)

        item.submenu = menu
        return item
    }

    // MARK: - Auth & Observers

    private func attemptAutoSignIn() {
        guard let webView = mainWindowController.playerWebView else { return }
        Task { @MainActor in
            _ = await AuthenticationManager.shared.attemptAutoSignIn(in: webView, timeout: 8.0)
        }
    }

    private func registerNotificationObservers() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(toggleMiniPlayer), name: .toggleMiniPlayer, object: nil)
        center.addObserver(self, selector: #selector(showPreferences), name: .showPreferences, object: nil)
        center.addObserver(self, selector: #selector(reloadYouTubeMusic), name: .reloadYouTubeMusic, object: nil)
        center.addObserver(self, selector: #selector(retryAuthentication), name: .retryAuthentication, object: nil)
        center.addObserver(self, selector: #selector(autoUpdateSettingChanged), name: .autoUpdateSettingChanged, object: nil)
    }

    @objc private func autoUpdateSettingChanged() {
        UpdateManager.shared.startAutoCheckIfEnabled()
    }

    @objc private func checkForUpdatesAction() {
        Task { @MainActor in
            await UpdateManager.shared.checkForUpdates(userInitiated: true)
        }
    }

    // MARK: - Actions

    @objc private func toggleMiniPlayer() {
        if let mini = miniPlayerController {
            if mini.window?.isVisible == true {
                mini.close()
                miniPlayerController = nil
            } else {
                mini.showWindow(nil)
            }
            return
        }

        let mini = MiniPlayerController()
        mini.onPlayPause = { [weak self] in await self?.evaluateJS(JavaScriptBridge.playPauseScript()) }
        mini.onNext = { [weak self] in await self?.evaluateJS(JavaScriptBridge.nextTrackScript()) }
        mini.onPrevious = { [weak self] in await self?.evaluateJS(JavaScriptBridge.previousTrackScript()) }
        mini.onShowMainWindow = { [weak self] in self?.showMainWindow() }
        mini.showWindow(nil)
        miniPlayerController = mini
    }

    @objc private func showPreferences() {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController()
        }
        preferencesWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showMainWindow() {
        mainWindowController.showWindow(nil)
        mainWindowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func playPauseAction() {
        Task { await evaluateJS(JavaScriptBridge.playPauseScript()) }
    }

    @objc private func nextTrackAction() {
        Task { await evaluateJS(JavaScriptBridge.nextTrackScript()) }
    }

    @objc private func previousTrackAction() {
        Task { await evaluateJS(JavaScriptBridge.previousTrackScript()) }
    }

    @objc private func toggleShuffleAction() {
        Task { await evaluateJS(JavaScriptBridge.toggleShuffleScript()) }
    }

    @objc private func toggleRepeatAction() {
        Task { await evaluateJS(JavaScriptBridge.toggleRepeatScript()) }
    }

    @objc private func reloadYouTubeMusic() {
        guard let webView = mainWindowController.playerWebView else { return }
        webView.load(URLRequest(url: URL(string: "https://music.youtube.com")!))
    }

    @objc private func retryAuthentication() {
        attemptAutoSignIn()
    }

    @MainActor
    private func evaluateJS(_ script: String) async {
        guard let webView = mainWindowController?.playerWebView else { return }
        _ = try? await webView.evaluateJavaScript(script)
    }
}
