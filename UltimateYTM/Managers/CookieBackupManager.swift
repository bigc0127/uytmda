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
import os.log

/// Backs up the WKWebView cookie jar to ~/Library/Application Support so that
/// third-party cleaners that wipe ~/Library/HTTPStorages don't sign the user
/// out of YouTube Music between launches.
@MainActor
final class CookieBackupManager {
    static let shared = CookieBackupManager()

    private let logger = Logger(subsystem: "com.ultimateytm.app", category: "CookieBackup")
    private let fm = FileManager.default
    private let bundleID = Bundle.main.bundleIdentifier ?? "com.ultimateytm.app"
    private var snapshotTimer: Timer?

    private init() {}

    // MARK: - Paths

    /// WKWebView's live cookie jar for a non-sandboxed app.
    private var liveCookiesURL: URL {
        fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/HTTPStorages/\(bundleID).binarycookies")
    }

    /// Backup location under Application Support — typically untouched by
    /// "browser cache" / "system junk" cleaners.
    private var backupDirURL: URL {
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent(bundleID, isDirectory: true)
    }

    private var backupCookiesURL: URL {
        backupDirURL.appendingPathComponent("cookies.binarycookies")
    }

    // MARK: - Restore (must run before WKWebView is initialized)

    /// If the live cookie file is missing or stub-sized but a backup exists,
    /// copy the backup back into place. Safe to call when no backup exists.
    func restoreIfNeeded() {
        let liveExists = fm.fileExists(atPath: liveCookiesURL.path)
        let liveSize = (try? fm.attributesOfItem(atPath: liveCookiesURL.path)[.size] as? Int) ?? 0
        let backupExists = fm.fileExists(atPath: backupCookiesURL.path)

        guard backupExists else { return }
        // Treat "missing" or "tiny stub" (< 100 bytes) as wiped.
        guard !liveExists || liveSize < 100 else { return }

        do {
            try fm.createDirectory(at: liveCookiesURL.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            if liveExists {
                try fm.removeItem(at: liveCookiesURL)
            }
            try fm.copyItem(at: backupCookiesURL, to: liveCookiesURL)
            logger.info("Restored cookies from backup — cleaner had wiped HTTPStorages")
        } catch {
            logger.error("Cookie restore failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Snapshot

    /// Copy the live cookie file to the backup location. No-op if no cookies yet.
    func snapshot() {
        guard fm.fileExists(atPath: liveCookiesURL.path) else { return }

        do {
            try fm.createDirectory(at: backupDirURL, withIntermediateDirectories: true)
            let tmp = backupCookiesURL.appendingPathExtension("tmp")
            if fm.fileExists(atPath: tmp.path) {
                try fm.removeItem(at: tmp)
            }
            try fm.copyItem(at: liveCookiesURL, to: tmp)
            if fm.fileExists(atPath: backupCookiesURL.path) {
                try fm.removeItem(at: backupCookiesURL)
            }
            try fm.moveItem(at: tmp, to: backupCookiesURL)
        } catch {
            logger.error("Cookie snapshot failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Periodic

    /// Start a repeating timer that snapshots cookies every `interval` seconds.
    func startPeriodicSnapshots(interval: TimeInterval = 600) {
        snapshotTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.snapshot() }
        }
        RunLoop.main.add(timer, forMode: .common)
        snapshotTimer = timer
    }

    func stopPeriodicSnapshots() {
        snapshotTimer?.invalidate()
        snapshotTimer = nil
    }
}
