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
import CryptoKit
import os.log

/// Self-rolled GitHub Releases auto-updater.
///
/// Flow:
///   1. GET /releases/latest from the GitHub REST API
///   2. Compare tag (sans leading "v") to `CFBundleShortVersionString`
///   3. If newer, prompt the user (Install / Later / Skip This Version)
///   4. Download .zip asset, optionally verify SHA-256
///   5. Extract via `ditto` to a staging dir
///   6. Spawn detached helper script that waits for our PID, swaps the
///      .app bundle, strips quarantine, and relaunches
///   7. `NSApp.terminate` — helper finishes the swap behind our back
///
/// No external dependencies. No silent install — every update is user-confirmed.
@MainActor
final class UpdateManager: NSObject {
    static let shared = UpdateManager()

    private let logger = Logger(subsystem: "com.ultimateytm.app", category: "Updates")
    private let releasesURL = URL(string: "https://api.github.com/repos/bigc0127/uytmda/releases/latest")!
    private let releasesPageURL = URL(string: "https://github.com/bigc0127/uytmda/releases")!

    private var autoCheckTimer: Timer?

    enum UpdateError: LocalizedError {
        case noAsset
        case downloadFailed(String)
        case extractionFailed(String)
        case integrityCheckFailed
        case readOnlyVolume
        case targetNotFound
        case rateLimited

        var errorDescription: String? {
            switch self {
            case .noAsset: return "Latest release has no .zip asset to download."
            case .downloadFailed(let msg): return "Download failed: \(msg)"
            case .extractionFailed(let msg): return "Could not unpack the update: \(msg)"
            case .integrityCheckFailed: return "Downloaded update failed SHA-256 integrity verification."
            case .readOnlyVolume: return "App is running from a read-only volume. Move it to /Applications first."
            case .targetNotFound: return "Could not locate the running app bundle on disk."
            case .rateLimited: return "GitHub rate limit reached. Try again later."
            }
        }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// True when running from Xcode's DerivedData — auto-update is skipped.
    var isDevelopmentBuild: Bool {
        let path = Bundle.main.bundlePath
        return path.contains("/DerivedData/") || path.contains("/Build/Products/")
    }

    // MARK: - Auto-check scheduling

    /// Restart the daily auto-check timer based on current settings. Safe to call repeatedly.
    func startAutoCheckIfEnabled() {
        autoCheckTimer?.invalidate()
        autoCheckTimer = nil

        guard AppSettings.shared.autoCheckUpdates else { return }
        guard !isDevelopmentBuild else {
            logger.info("Skipping auto-update: development build")
            return
        }

        // Initial check ~10s after launch so we don't slow startup.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            await self?.checkForUpdates(userInitiated: false)
        }

        let timer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkForUpdates(userInitiated: false)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoCheckTimer = timer
    }

    // MARK: - Check

    /// Check the latest release. `userInitiated=true` shows confirmation dialogs even when up-to-date or on error.
    func checkForUpdates(userInitiated: Bool) async {
        AppSettings.shared.lastUpdateCheckDate = Date()

        do {
            let release = try await fetchLatestRelease()

            if release.prerelease || release.draft {
                logger.info("Latest release is prerelease/draft — ignoring")
                if userInitiated { presentUpToDateAlert() }
                return
            }

            let latest = release.versionString
            let current = currentVersion

            if !semverLessThan(current, latest) {
                logger.info("Up to date (current=\(current), latest=\(latest))")
                if userInitiated { presentUpToDateAlert() }
                return
            }

            // Honor "Skip This Version" unless the user explicitly initiated.
            if !userInitiated,
               let skipped = AppSettings.shared.skippedUpdateVersion,
               skipped == latest {
                logger.info("Skipping previously-skipped version \(latest)")
                return
            }

            await presentUpdateAvailable(release: release)
        } catch {
            logger.error("Update check failed: \(error.localizedDescription)")
            if userInitiated { presentErrorAlert(error) }
        }
    }

    private func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("UltimateYTM-Updater/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 403, 429:
                throw UpdateError.rateLimited
            case 200..<300:
                break
            default:
                throw UpdateError.downloadFailed("HTTP \(http.statusCode)")
            }
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let container = try d.singleValueContainer()
            let s = try container.decode(String.self)
            // Recreate formatter per-call: ISO8601DateFormatter is not Sendable.
            return ISO8601DateFormatter().date(from: s) ?? Date()
        }
        return try decoder.decode(GitHubRelease.self, from: data)
    }

    // MARK: - User-facing prompts

    private func presentUpdateAvailable(release: GitHubRelease) async {
        let alert = NSAlert()
        alert.messageText = "Update Available — v\(release.versionString)"
        let notes = (release.body ?? "").prefix(800)
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.informativeText = "You're running v\(currentVersion). A new version is available."
            + (trimmed.isEmpty ? "" : "\n\n\(trimmed)")
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install Update")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            await downloadAndInstall(release: release)
        case .alertThirdButtonReturn:
            AppSettings.shared.skippedUpdateVersion = release.versionString
        default:
            break
        }
    }

    private func presentUpToDateAlert() {
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "Ultimate YTM v\(currentVersion) is the latest version."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }

    private func presentErrorAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Update Check Failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Releases Page")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(releasesPageURL)
        }
    }

    // MARK: - Download & install

    private func downloadAndInstall(release: GitHubRelease) async {
        guard let asset = release.zipAsset else {
            presentErrorAlert(UpdateError.noAsset)
            return
        }

        // Indeterminate progress window
        let progressWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 110),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        progressWindow.title = "Updating to v\(release.versionString)"
        progressWindow.center()
        progressWindow.level = .modalPanel

        let label = NSTextField(labelWithString: "Downloading…")
        label.frame = NSRect(x: 20, y: 70, width: 320, height: 20)
        let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 35, width: 320, height: 20))
        bar.style = .bar
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        progressWindow.contentView?.addSubview(label)
        progressWindow.contentView?.addSubview(bar)
        progressWindow.makeKeyAndOrderFront(nil)

        defer {
            bar.stopAnimation(nil)
            progressWindow.close()
        }

        do {
            let zipURL = try await downloadZip(asset: asset)

            if let expected = release.expectedSHA256 {
                label.stringValue = "Verifying…"
                let actual = try await sha256Hex(of: zipURL)
                if actual != expected {
                    logger.error("SHA256 mismatch (expected=\(expected), actual=\(actual))")
                    throw UpdateError.integrityCheckFailed
                }
                logger.info("SHA256 verified")
            }

            label.stringValue = "Installing…"
            try await install(zipURL: zipURL, version: release.versionString)
            // install() does not return — it spawns the helper and terminates this app.
        } catch {
            logger.error("Install failed: \(error.localizedDescription)")
            presentErrorAlert(error)
        }
    }

    private func downloadZip(asset: GitHubRelease.Asset) async throws -> URL {
        let cacheDir = try cacheDirectory()
        let dest = cacheDir.appendingPathComponent(asset.name)
        try? FileManager.default.removeItem(at: dest)

        let (tmpURL, response) = try await URLSession.shared.download(from: asset.browserDownloadURL)
        if let http = response as? HTTPURLResponse, !(200..<300 ~= http.statusCode) {
            throw UpdateError.downloadFailed("HTTP \(http.statusCode)")
        }
        try FileManager.default.moveItem(at: tmpURL, to: dest)
        return dest
    }

    private func cacheDirectory() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("com.ultimateytm.app/updates", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private nonisolated func sha256Hex(of url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let data = try Data(contentsOf: url)
            let digest = SHA256.hash(data: data)
            return digest.map { String(format: "%02x", $0) }.joined()
        }.value
    }

    /// Extract the zip and spawn the swap-and-relaunch helper. Terminates the app on success.
    private func install(zipURL: URL, version: String) async throws {
        let fm = FileManager.default
        let bundleURL = Bundle.main.bundleURL

        if isDevelopmentBuild {
            throw UpdateError.targetNotFound
        }

        let resourceValues = try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        if resourceValues?.volumeIsReadOnly == true {
            throw UpdateError.readOnlyVolume
        }

        // Stage in a uniquely named temp dir
        let stagingParent = fm.temporaryDirectory
            .appendingPathComponent("UltimateYTM-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stagingParent, withIntermediateDirectories: true)

        // Extract via ditto on a background thread
        let zipPath = zipURL.path
        let stagingPath = stagingParent.path
        let extractResult: (Int32, String) = try await Task.detached(priority: .utility) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            proc.arguments = ["-x", "-k", zipPath, stagingPath]
            let pipe = Pipe()
            proc.standardError = pipe
            proc.standardOutput = Pipe()
            try proc.run()
            proc.waitUntilExit()
            let stderr = String(
                data: pipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            return (proc.terminationStatus, stderr)
        }.value

        guard extractResult.0 == 0 else {
            throw UpdateError.extractionFailed(extractResult.1.isEmpty ? "ditto exit \(extractResult.0)" : extractResult.1)
        }

        // Locate the .app produced by extraction
        let contents = try fm.contentsOfDirectory(at: stagingParent, includingPropertiesForKeys: nil)
        guard let stagedApp = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.extractionFailed("No .app bundle found in archive")
        }

        // Build helper bash script. Quote-escape paths in case anyone has spaces in /Applications
        // (rare but real). We deliberately use plain bash so we don't inherit any sandbox quirks.
        let pid = ProcessInfo.processInfo.processIdentifier
        let helperPath = fm.temporaryDirectory.appendingPathComponent("uytmd-update-helper-\(UUID().uuidString).sh")
        let target = bundleURL.path.replacingOccurrences(of: "\"", with: "\\\"")
        let staged = stagedApp.path.replacingOccurrences(of: "\"", with: "\\\"")
        let stagingEsc = stagingParent.path.replacingOccurrences(of: "\"", with: "\\\"")

        // Per-run log file so we can post-mortem failed swaps.
        let logPath = "/tmp/uytmd-update-\(Int(Date().timeIntervalSince1970)).log"

        // Helper script: self-daemonizes via nohup+disown so it survives parent
        // app termination, logs every step to /tmp for forensics.
        let script = """
        #!/bin/bash
        LOGFILE="\(logPath)"
        exec >>"$LOGFILE" 2>&1
        echo "[$(date '+%H:%M:%S')] === helper invoked, daemon=${UYTM_DAEMON:-0}, pid=$$, ppid=$PPID ==="

        # Stage 1: re-exec ourselves detached from the parent app's process group.
        # Without this, macOS may kill the helper when the GUI app terminates
        # (process-group SIGHUP propagation), leaving the swap unfinished.
        if [ "${UYTM_DAEMON:-}" != "1" ]; then
            export UYTM_DAEMON=1
            nohup "$0" "$@" </dev/null >>"$LOGFILE" 2>&1 &
            BG_PID=$!
            disown
            echo "[$(date '+%H:%M:%S')] backgrounded as PID $BG_PID, exiting first stage"
            exit 0
        fi

        # Stage 2: actual swap logic, running detached.
        echo "[$(date '+%H:%M:%S')] DAEMON STAGE: pid=$$ ppid=$PPID"

        set -u
        PARENT_PID=\(pid)
        TARGET="\(target)"
        STAGED="\(staged)"
        STAGING_DIR="\(stagingEsc)"
        SELF="$0"

        # Wait for parent to exit (max ~30s)
        for i in $(seq 1 150); do
            if ! kill -0 "$PARENT_PID" 2>/dev/null; then
                echo "[$(date '+%H:%M:%S')] parent $PARENT_PID exited after iteration $i"
                break
            fi
            sleep 0.2
        done
        sleep 0.5

        # Replace target bundle
        if [ -d "$TARGET" ]; then
            echo "[$(date '+%H:%M:%S')] removing existing $TARGET"
            rm -rf "$TARGET"
            RC=$?
            echo "[$(date '+%H:%M:%S')] rm exit=$RC"
            if [ "$RC" -ne 0 ]; then
                echo "[$(date '+%H:%M:%S')] ABORT: cannot remove existing app"
                exit 1
            fi
        fi

        echo "[$(date '+%H:%M:%S')] mv $STAGED -> $TARGET"
        mv "$STAGED" "$TARGET"
        RC=$?
        echo "[$(date '+%H:%M:%S')] mv exit=$RC"
        if [ "$RC" -ne 0 ]; then
            echo "[$(date '+%H:%M:%S')] ABORT: mv failed"
            exit 1
        fi

        # Strip quarantine so Gatekeeper doesn't re-prompt unnecessarily
        xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
        echo "[$(date '+%H:%M:%S')] xattr stripped"

        # Cleanup leftover staging dir
        rm -rf "$STAGING_DIR" 2>/dev/null || true
        echo "[$(date '+%H:%M:%S')] staging cleaned"

        # Relaunch the new app
        open "$TARGET"
        echo "[$(date '+%H:%M:%S')] open exit=$?"

        # Self-cleanup
        rm -- "$SELF" 2>/dev/null || true
        echo "[$(date '+%H:%M:%S')] DONE"
        """
        try script.write(to: helperPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperPath.path)

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/bash")
        helper.arguments = [helperPath.path]
        // Keep all std streams open (nil = inherit from us) — the helper
        // redirects them itself in stage 1.
        try helper.run()

        // Give helper enough time to fully self-daemonize (stage 1 → stage 2).
        // Stage 1 is brief (single nohup + disown + exit). 1s is generous.
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        logger.info("Installer helper launched (log: \(logPath)). Terminating to allow swap.")
        NSApp.terminate(nil)
    }
}
