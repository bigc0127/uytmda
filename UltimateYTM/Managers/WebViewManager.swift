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

@MainActor
protocol WebViewManagerDelegate: AnyObject {
    func webViewManager(_ manager: WebViewManager, didUpdateTrackInfo trackInfo: TrackInfo)
    func webViewManagerDidLoad(_ manager: WebViewManager)
}

@MainActor
class WebViewManager: NSObject {
    weak var delegate: WebViewManagerDelegate?
    
    private(set) var webView: WKWebView!
    private var trackInfoTimer: Timer?
    private(set) var currentTrackInfo: TrackInfo = .empty
    
    private let youTubeMusicURL = URL(string: "https://music.youtube.com")!
    
    override init() {
        super.init()
        setupWebView()
    }
    
    private func setupWebView() {
        // Get configuration from AuthenticationManager with persistent data store
        let config = AuthenticationManager.shared.webViewConfiguration()
        
        // Set up user content controller for JavaScript messaging
        let contentController = WKUserContentController()
        contentController.add(self, name: "trackChanged")
        contentController.addUserScript(JavaScriptBridge.createAutoUpdateUserScript())
        
        // Override MediaSession to use previous/next track instead of seek
        let mediaSessionOverride = WKUserScript(
            source: """
            // Aggressively override MediaSession to force previous/next track controls
            (function() {
                console.log('[UltimateYTM] Starting MediaSession override');
                
                // Store original setActionHandler
                var originalSetActionHandler = null;
                
                function getPlayerButtons() {
                    return {
                        previous: document.querySelector('button[aria-label="Previous track"], .previous-button, ytmusic-player-bar button:nth-child(2)'),
                        next: document.querySelector('button[aria-label="Next track"], .next-button, ytmusic-player-bar button:nth-child(4)')
                    };
                }
                
                function setupActions() {
                    if (!navigator.mediaSession) return false;
                    
                    try {
                        var buttons = getPlayerButtons();
                        
                        // Clear all seek-related actions
                        navigator.mediaSession.setActionHandler('seekbackward', null);
                        navigator.mediaSession.setActionHandler('seekforward', null);
                        navigator.mediaSession.setActionHandler('seekto', null);
                        
                        // Set track navigation
                        navigator.mediaSession.setActionHandler('previoustrack', function() {
                            console.log('[UltimateYTM] Previous track triggered');
                            var btn = getPlayerButtons().previous;
                            if (btn) btn.click();
                        });
                        
                        navigator.mediaSession.setActionHandler('nexttrack', function() {
                            console.log('[UltimateYTM] Next track triggered');
                            var btn = getPlayerButtons().next;
                            if (btn) btn.click();
                        });
                        
                        console.log('[UltimateYTM] MediaSession actions set successfully');
                        return true;
                    } catch(e) {
                        console.error('[UltimateYTM] Error setting MediaSession:', e);
                        return false;
                    }
                }
                
                // Intercept setActionHandler calls from YouTube Music
                if (navigator.mediaSession) {
                    originalSetActionHandler = navigator.mediaSession.setActionHandler;
                    navigator.mediaSession.setActionHandler = function(action, handler) {
                        // Block seek actions, allow others
                        if (action === 'seekbackward' || action === 'seekforward' || action === 'seekto') {
                            console.log('[UltimateYTM] Blocked', action, 'from YouTube Music');
                            return originalSetActionHandler.call(this, action, null);
                        }
                        return originalSetActionHandler.call(this, action, handler);
                    };
                }
                
                // Keep trying to set up actions
                var setupInterval = setInterval(function() {
                    if (setupActions()) {
                        // Keep re-applying every 2 seconds to override YouTube Music's changes
                        setTimeout(function() {
                            setInterval(setupActions, 2000);
                        }, 5000);
                        clearInterval(setupInterval);
                    }
                }, 500);
                
                // Also set up on play/pause events
                document.addEventListener('play', setupActions, true);
                document.addEventListener('pause', setupActions, true);
            })();
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        contentController.addUserScript(mediaSessionOverride)
        
        config.userContentController = contentController
        
        // Create web view
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = false
        
        // Custom user agent for desktop YouTube Music
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        
        // Load YouTube Music
        let request = URLRequest(url: youTubeMusicURL)
        webView.load(request)
    }
    
    // MARK: - Track Info Management
    
    func startTrackInfoPolling() {
        trackInfoTimer?.invalidate()
        trackInfoTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.updateTrackInfo()
            }
        }
        RunLoop.main.add(trackInfoTimer!, forMode: .common)
    }
    
    func stopTrackInfoPolling() {
        trackInfoTimer?.invalidate()
        trackInfoTimer = nil
    }
    
    func updateTrackInfo() async {
        do {
            let result = try await webView.evaluateJavaScript(JavaScriptBridge.trackInfoScript)
            
            guard let jsonString = result as? String,
                  let jsonData = jsonString.data(using: .utf8),
                  let trackInfo = try? JSONDecoder().decode(TrackInfo.self, from: jsonData) else {
                return
            }
            
            if trackInfo != currentTrackInfo {
                currentTrackInfo = trackInfo
                
                // Download artwork if needed
                if let artworkURL = trackInfo.artworkURL,
                   let url = URL(string: artworkURL) {
                    Task {
                        if let (data, _) = try? await URLSession.shared.data(from: url),
                           let image = NSImage(data: data) {
                            var updatedTrackInfo = trackInfo
                            updatedTrackInfo.artworkImage = image
                            self.currentTrackInfo = updatedTrackInfo
                            self.delegate?.webViewManager(self, didUpdateTrackInfo: updatedTrackInfo)
                        } else {
                            self.delegate?.webViewManager(self, didUpdateTrackInfo: trackInfo)
                        }
                    }
                } else {
                    delegate?.webViewManager(self, didUpdateTrackInfo: trackInfo)
                }
            }
        } catch {
            print("Error updating track info: \(error)")
        }
    }
    
    // MARK: - Playback Control
    
    func playPause() async {
        _ = try? await webView.evaluateJavaScript(JavaScriptBridge.playPauseScript())
        // Immediately update track info
        await updateTrackInfo()
    }
    
    func nextTrack() async {
        _ = try? await webView.evaluateJavaScript(JavaScriptBridge.nextTrackScript())
        // Wait a bit for track change, then update
        _ = try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        await updateTrackInfo()
    }
    
    func previousTrack() async {
        _ = try? await webView.evaluateJavaScript(JavaScriptBridge.previousTrackScript())
        // Wait a bit for track change, then update
        _ = try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        await updateTrackInfo()
    }
    
    func setVolume(_ volume: Float) async {
        _ = try? await webView.evaluateJavaScript(JavaScriptBridge.setVolumeScript(volume: volume))
    }
    
    func toggleShuffle() async {
        _ = try? await webView.evaluateJavaScript(JavaScriptBridge.toggleShuffleScript())
        await updateTrackInfo()
    }
    
    func toggleRepeat() async {
        _ = try? await webView.evaluateJavaScript(JavaScriptBridge.toggleRepeatScript())
        await updateTrackInfo()
    }
    
    func seekTo(time: TimeInterval) async {
        _ = try? await webView.evaluateJavaScript(JavaScriptBridge.seekToScript(time: time))
        await updateTrackInfo()
    }
    
    // MARK: - Authentication
    
    func loadYouTubeMusicHome() {
        let request = URLRequest(url: youTubeMusicURL)
        webView.load(request)
    }
    
    func evaluateAuthState() async -> Bool {
        return await AuthenticationManager.shared.isAuthenticated(in: webView)
    }
}

// MARK: - WKNavigationDelegate

extension WebViewManager: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            // Check auth state after navigation completes
            let isAuthed = await AuthenticationManager.shared.isAuthenticated(in: webView)
            if isAuthed {
                let settings = AppSettings.shared
                settings.lastAuthenticationStatus = "authenticated"
                settings.lastAuthenticationDate = Date()
            }
            
            // Wait for page to fully load before starting polling
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            startTrackInfoPolling()
            delegate?.webViewManagerDidLoad(self)
        }
    }
    
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("WebView navigation failed: \(error.localizedDescription)")
    }
}

// MARK: - WKScriptMessageHandler

extension WebViewManager: WKScriptMessageHandler {
    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // Suppress warning for accessing message.name from nonisolated context
        // This is safe as we're just comparing the string value
        Task { @MainActor [weak self, message] in
            guard let self = self else { return }
            switch message.name {
            case "trackChanged":
                // Track change detected from JavaScript
                await self.updateTrackInfo()
            default:
                break
            }
        }
    }
}
