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
import SwiftUI

@MainActor
class PreferencesWindowController: NSWindowController {
    convenience init() {
        let hosting = NSHostingController(rootView: PreferencesView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 480, height: 540))
        window.center()
        window.isReleasedWhenClosed = false
        self.init(window: window)
    }
}

private struct PreferencesView: View {
    @State private var selection: Tab = .general

    enum Tab: Hashable {
        case general, playback, account
    }

    var body: some View {
        TabView(selection: $selection) {
            GeneralPane()
                .tabItem { Label("General", systemImage: "gear") }
                .tag(Tab.general)

            PlaybackPane()
                .tabItem { Label("Playback", systemImage: "play.circle") }
                .tag(Tab.playback)

            AccountPane()
                .tabItem { Label("Account", systemImage: "person.circle") }
                .tag(Tab.account)
        }
        .frame(width: 480, height: 500)
        .padding(.top, 12)
    }
}

private struct GeneralPane: View {
    @State private var showEqualizer = AppSettings.shared.showEqualizer
    @State private var equalizerWidth = AppSettings.shared.equalizerWidthOverride
    @State private var showNotifications = AppSettings.shared.showNotifications
    @State private var notifyOnTrackChange = AppSettings.shared.notifyOnTrackChange
    @State private var miniPlayerOnTop = AppSettings.shared.miniPlayerOnTop

    private var screenWidth: Double {
        Double(NSScreen.main?.frame.width ?? 1920)
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Toggle("Show rainbow audio equalizer along Dock", isOn: $showEqualizer)
                    .onChange(of: showEqualizer) { _, newValue in
                        AppSettings.shared.showEqualizer = newValue
                    }

                if showEqualizer {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Dock pill width")
                            Spacer()
                            Text(equalizerWidth > 0 ? "\(Int(equalizerWidth)) px" : "Auto")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $equalizerWidth, in: 0...screenWidth, step: 10)
                            .onChange(of: equalizerWidth) { _, newValue in
                                AppSettings.shared.equalizerWidthOverride = newValue
                            }
                        Text("Slide right to dial in your Dock pill width. Set to 0 (Auto) for full-width fallback.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Notifications") {
                Toggle("Enable desktop notifications", isOn: $showNotifications)
                    .onChange(of: showNotifications) { _, newValue in
                        AppSettings.shared.showNotifications = newValue
                    }
                Toggle("Notify when the track changes", isOn: $notifyOnTrackChange)
                    .disabled(!showNotifications)
                    .onChange(of: notifyOnTrackChange) { _, newValue in
                        AppSettings.shared.notifyOnTrackChange = newValue
                    }
            }

            Section("Mini Player") {
                Toggle("Keep mini player above other windows", isOn: $miniPlayerOnTop)
                    .onChange(of: miniPlayerOnTop) { _, newValue in
                        AppSettings.shared.miniPlayerOnTop = newValue
                    }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

private struct PlaybackPane: View {
    var body: some View {
        Form {
            Section("Keyboard Shortcuts") {
                LabeledContent("Play / Pause", value: "⌘⇧Space")
                LabeledContent("Next Track", value: "⌘⇧→")
                LabeledContent("Previous Track", value: "⌘⇧←")
                LabeledContent("Toggle Shuffle", value: "⌘⇧S")
                LabeledContent("Toggle Repeat", value: "⌘⇧R")
                LabeledContent("Toggle Mini Player", value: "⌘⇧M")
            }

            Section {
                Text("Media keys (F7/F8/F9) and headphone controls work via the system Now Playing service. They route to whichever app is the active media source.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

private struct AccountPane: View {
    @State private var status: AuthenticationManager.AuthStatus = .unknown
    @State private var lastDate: Date? = AppSettings.shared.lastAuthenticationDate
    @State private var isSigningOut = false

    var body: some View {
        Form {
            Section("YouTube Music Account") {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                        Text(statusText)
                    }
                }

                if let lastDate {
                    LabeledContent("Last Verified", value: lastDate.formatted(date: .abbreviated, time: .shortened))
                }
            }

            Section {
                Button("Retry Sign In", action: retry)
                Button("Sign Out and Clear Cookies…", role: .destructive, action: signOut)
                    .disabled(status != .authenticated && status != .unknown)
            }

            Section {
                Text("Safari sessions are not accessible to apps. If automatic sign-in fails, sign in manually inside the main window.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear { refresh() }
    }

    private var statusText: String {
        switch status {
        case .authenticated: "Signed in"
        case .unauthenticated: "Not signed in"
        case .unknown: "Unknown"
        }
    }

    private var statusColor: Color {
        switch status {
        case .authenticated: .green
        case .unauthenticated: .orange
        case .unknown: .secondary
        }
    }

    private func refresh() {
        status = AuthenticationManager.shared.getCurrentAuthStatus()
        lastDate = AppSettings.shared.lastAuthenticationDate
    }

    private func retry() {
        NotificationCenter.default.post(name: .retryAuthentication, object: nil)
        refresh()
    }

    private func signOut() {
        let alert = NSAlert()
        alert.messageText = "Sign Out"
        alert.informativeText = "This clears all cookies and signs you out of YouTube Music. You'll need to sign in again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Sign Out")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        isSigningOut = true
        Task { @MainActor in
            await AuthenticationManager.shared.clearYouTubeCookies()
            NotificationCenter.default.post(name: .reloadYouTubeMusic, object: nil)
            isSigningOut = false
            refresh()
        }
    }
}

extension Notification.Name {
    static let reloadYouTubeMusic = Notification.Name("reloadYouTubeMusic")
    static let retryAuthentication = Notification.Name("retryAuthentication")
}
