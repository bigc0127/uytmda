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
import WebKit
import os.log

@MainActor
class AuthenticationManager {
    static let shared = AuthenticationManager()
    
    private let logger = Logger(subsystem: "com.ultimateytm.app", category: "Authentication")
    private let youTubeMusicURL = URL(string: "https://music.youtube.com")!
    
    private init() {}
    
    // MARK: - WebView Configuration
    
    func webViewConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        
        // Use default persistent data store to maintain cookies across launches
        config.websiteDataStore = WKWebsiteDataStore.default()
        
        // Configure for optimal media playback
        config.mediaTypesRequiringUserActionForPlayback = []
        
        // Set application name for user agent
        config.applicationNameForUserAgent = "UltimateYTM"
        
        return config
    }
    
    // MARK: - Authentication Detection
    
    /// JavaScript to detect if user is signed in to YouTube Music
    private var authDetectionScript: String {
        """
        (function() {
            // Heuristic 1: "Sign in" link present when logged out
            var signInLink = document.querySelector('a[href*="ServiceLogin"][href*="youtube"]');
            
            // Heuristic 2: ytcfg LOGGED_IN flag, when available
            var loggedFlag = false;
            try {
                if (window.ytcfg && ytcfg.get) {
                    loggedFlag = ytcfg.get('LOGGED_IN') === true;
                }
            } catch (e) {
                // ytcfg not available or error accessing it
            }
            
            // Heuristic 3: user avatar/menu presence in top bar (Music layout)
            var avatar = document.querySelector('ytmusic-nav-bar a[aria-label*="Account"], ytmusic-nav-bar tp-yt-paper-icon-button[aria-label*="Account"], ytmusic-nav-bar a[href*="account"], ytmusic-nav-bar button[aria-label*="Account"]');
            
            var isLoggedIn = loggedFlag || (!!avatar && !signInLink);
            
            return {
                isLoggedIn: !!isLoggedIn,
                hasSignInLink: !!signInLink,
                hasAvatar: !!avatar,
                ytcfgFlag: loggedFlag
            };
        })();
        """
    }
    
    /// Checks if the user is authenticated in the given WebView
    func isAuthenticated(in webView: WKWebView) async -> Bool {
        do {
            let result = try await webView.evaluateJavaScript(authDetectionScript)
            
            guard let dict = result as? [String: Any],
                  let isLoggedIn = dict["isLoggedIn"] as? Bool else {
                logger.warning("Auth detection returned unexpected format")
                return false
            }
            
            let hasSignInLink = dict["hasSignInLink"] as? Bool ?? false
            let hasAvatar = dict["hasAvatar"] as? Bool ?? false
            let ytcfgFlag = dict["ytcfgFlag"] as? Bool ?? false
            
            logger.info("Auth state: isLoggedIn=\(isLoggedIn), signInLink=\(hasSignInLink), avatar=\(hasAvatar), ytcfg=\(ytcfgFlag)")
            
            return isLoggedIn
        } catch {
            logger.error("Failed to evaluate auth state: \(error.localizedDescription)")
            return false
        }
    }
    
    /// Attempts to auto sign-in by checking if existing cookies provide authentication
    func attemptAutoSignIn(in webView: WKWebView, timeout: TimeInterval = 8.0) async -> Bool {
        logger.info("🔐 Attempting auto sign-in via cookie reuse (timeout: \(timeout)s)")
        
        // Load YouTube Music if not already loaded
        let currentURL = webView.url
        if currentURL?.host != youTubeMusicURL.host {
            logger.info("Loading YouTube Music...")
            let request = URLRequest(url: youTubeMusicURL)
            webView.load(request)
        }
        
        // Retry logic: check auth state multiple times
        let maxRetries = 3
        let retryDelay: UInt64 = 2_000_000_000 // 2 seconds
        
        for attempt in 1...maxRetries {
            // Wait for page to load/render
            try? await Task.sleep(nanoseconds: retryDelay)
            
            logger.info("Auth check attempt \(attempt)/\(maxRetries)")
            
            let isAuthed = await isAuthenticated(in: webView)
            
            if isAuthed {
                logger.info("✅ Auto sign-in successful!")
                await updateAuthStatus(.authenticated)
                return true
            }
            
            // Check if we've exceeded timeout
            if TimeInterval(attempt) * (Double(retryDelay) / 1_000_000_000) >= timeout {
                break
            }
        }
        
        logger.info("❌ Auto sign-in failed - user needs to sign in manually")
        await updateAuthStatus(.unauthenticated)
        return false
    }
    
    // MARK: - Cookie Management
    
    /// Clears all YouTube and Google cookies and site data
    func clearYouTubeCookies() async {
        logger.info("🗑️ Clearing YouTube/Google cookies and site data")
        
        let dataStore = WKWebsiteDataStore.default()
        let cookieStore = dataStore.httpCookieStore
        
        // Get all cookies
        let allCookies = await cookieStore.allCookies()
        
        // Filter and delete YouTube/Google cookies
        var deletedCount = 0
        for cookie in allCookies {
            if cookie.domain.contains("youtube.com") || 
               cookie.domain.contains("google.com") ||
               cookie.domain.contains("gstatic.com") {
                await cookieStore.delete(cookie)
                deletedCount += 1
            }
        }
        
        logger.info("Deleted \(deletedCount) cookies")
        
        // Clear website data
        let dataTypes = Set([
            WKWebsiteDataTypeCookies,
            WKWebsiteDataTypeLocalStorage,
            WKWebsiteDataTypeSessionStorage,
            WKWebsiteDataTypeIndexedDBDatabases,
            WKWebsiteDataTypeServiceWorkerRegistrations,
            WKWebsiteDataTypeWebSQLDatabases,
            WKWebsiteDataTypeFetchCache,
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache
        ])
        
        let records = await dataStore.dataRecords(ofTypes: dataTypes)
        let targetRecords = records.filter { 
            $0.displayName.contains("youtube") || 
            $0.displayName.contains("google") 
        }
        
        if !targetRecords.isEmpty {
            await dataStore.removeData(ofTypes: dataTypes, for: targetRecords)
            logger.info("Cleared website data for \(targetRecords.count) records")
        }
        
        await updateAuthStatus(.unauthenticated)
        logger.info("✅ Cookie clearing complete")
    }
    
    // MARK: - Status Persistence
    
    enum AuthStatus: String {
        case unknown
        case authenticated
        case unauthenticated
    }
    
    private func updateAuthStatus(_ status: AuthStatus) async {
        let settings = AppSettings.shared
        settings.lastAuthenticationStatus = status.rawValue
        
        if status == .authenticated {
            settings.lastAuthenticationDate = Date()
        }
    }
    
    func getCurrentAuthStatus() -> AuthStatus {
        let statusString = AppSettings.shared.lastAuthenticationStatus
        return AuthStatus(rawValue: statusString) ?? .unknown
    }
}

// Extension to add async/await support for WKHTTPCookieStore
extension WKHTTPCookieStore {
    func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            self.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }
    
    func delete(_ cookie: HTTPCookie) async {
        await withCheckedContinuation { continuation in
            self.delete(cookie) {
                continuation.resume()
            }
        }
    }
}

// Extension to add async/await support for WKWebsiteDataStore
extension WKWebsiteDataStore {
    func dataRecords(ofTypes types: Set<String>) async -> [WKWebsiteDataRecord] {
        await withCheckedContinuation { continuation in
            self.fetchDataRecords(ofTypes: types) { records in
                continuation.resume(returning: records)
            }
        }
    }
    
    func removeData(ofTypes types: Set<String>, for records: [WKWebsiteDataRecord]) async {
        await withCheckedContinuation { continuation in
            self.removeData(ofTypes: types, for: records) {
                continuation.resume()
            }
        }
    }
}
