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

class JavaScriptBridge {
    // JavaScript code to inject into YouTube Music for extracting track info
    static let trackInfoScript = """
    (function() {
        function getTrackInfo() {
            const video = document.querySelector('video');
            const titleElement = document.querySelector('.title.style-scope.ytmusic-player-bar');
            const artistElement = document.querySelector('.byline.style-scope.ytmusic-player-bar a');
            const albumElement = document.querySelector('.byline.style-scope.ytmusic-player-bar a:nth-child(3)');
            const artworkElement = document.querySelector('.image.style-scope.ytmusic-player-bar');
            const shuffleButton = document.querySelector('#shuffle-button');
            const repeatButton = document.querySelector('#repeat-button');
            
            let artworkURL = null;
            // 1. MediaSession metadata is the most reliable source on YT Music.
            try {
                const md = navigator.mediaSession && navigator.mediaSession.metadata;
                if (md && md.artwork && md.artwork.length) {
                    artworkURL = md.artwork[md.artwork.length - 1].src;
                }
            } catch (e) {}
            // 2. Fall back to the player-bar thumbnail: <img> src, or CSS background.
            if (!artworkURL && artworkElement) {
                if (artworkElement.tagName === 'IMG' && artworkElement.src) {
                    artworkURL = artworkElement.src;
                } else if (artworkElement.style && artworkElement.style.backgroundImage) {
                    const match = artworkElement.style.backgroundImage.match(/url\\("?(.+?)"?\\)/);
                    if (match && match[1]) { artworkURL = match[1]; }
                }
            }
            // 3. Last resort: any image inside the player bar.
            if (!artworkURL) {
                const img = document.querySelector('ytmusic-player-bar img, .image.ytmusic-player-bar img, img.image.ytmusic-player-bar');
                if (img && img.src) { artworkURL = img.src; }
            }
            // Upscale googleusercontent thumbnails to a crisp square.
            if (artworkURL && artworkURL.indexOf('googleusercontent') !== -1) {
                artworkURL = artworkURL.split('=')[0] + '=w544-h544-l90-rj';
            }
            
            let repeatMode = 'NONE';
            if (repeatButton) {
                const ariaLabel = repeatButton.getAttribute('aria-label');
                if (ariaLabel && ariaLabel.includes('one')) {
                    repeatMode = 'ONE';
                } else if (repeatButton.getAttribute('aria-pressed') === 'true') {
                    repeatMode = 'ALL';
                }
            }

            // Rating: like-button-renderer exposes like-status LIKE/DISLIKE/INDIFFERENT.
            let rating = '';
            try {
                const likeRenderer = document.querySelector('ytmusic-player-bar ytmusic-like-button-renderer');
                if (likeRenderer) {
                    const status = likeRenderer.getAttribute('like-status');
                    if (status === 'LIKE') { rating = 'up'; }
                    else if (status === 'DISLIKE') { rating = 'down'; }
                }
            } catch (e) {}

            // Library: read the current track's save/library toggle from the
            // player-bar action-menu DATA MODEL — no need to open the menu. YT Music
            // exposes the menu items on `ytmusic-menu-renderer`.data; the track-level
            // toggle's defaultText is per-track and state-driven (verified live):
            //   "Remove from library" => in library; "Save to library" => not.
            // Exact-anchored match excludes the playlist/mix "Save … to library"
            // variants. BFS is bounded and fully guarded; defaults false.
            let inLibrary = false;
            try {
                const bar = document.querySelector('ytmusic-player-bar');
                const mr = bar && bar.querySelector('ytmusic-menu-renderer');
                if (mr) {
                    const roots = [mr.data, mr.__data].filter(Boolean);
                    const q = roots.slice(); const visited = []; let count = 0;
                    while (q.length && count < 4000) {
                        const o = q.shift(); count++;
                        if (!o || typeof o !== 'object' || visited.indexOf(o) !== -1) { continue; }
                        visited.push(o);
                        try {
                            const dt = o.defaultText && o.defaultText.runs && o.defaultText.runs[0] && o.defaultText.runs[0].text;
                            if (dt && /^remove from library$/i.test(dt)) { inLibrary = true; break; }
                            if (dt && /^save to library$/i.test(dt)) { inLibrary = false; break; }
                        } catch (e) {}
                        for (const k in o) { try { const v = o[k]; if (v && typeof v === 'object') { q.push(v); } } catch (e) {} }
                    }
                }
            } catch (e) {}

            return {
                title: titleElement ? titleElement.textContent.trim() : '',
                artist: artistElement ? artistElement.textContent.trim() : '',
                album: albumElement ? albumElement.textContent.trim() : '',
                duration: video ? video.duration : 0,
                currentTime: video ? video.currentTime : 0,
                artworkURL: artworkURL,
                isPaused: video ? video.paused : true,
                isShuffled: shuffleButton ? shuffleButton.getAttribute('aria-pressed') === 'true' : false,
                repeatMode: repeatMode,
                rating: rating,
                inLibrary: inLibrary
            };
        }
        
        return JSON.stringify(getTrackInfo());
    })();
    """
    
    // JavaScript code to control playback
    static func playPauseScript() -> String {
        """
        (function() {
            const video = document.querySelector('video');
            if (video) {
                if (video.paused) {
                    video.play();
                } else {
                    video.pause();
                }
                return true;
            }
            return false;
        })();
        """
    }
    
    static func nextTrackScript() -> String {
        """
        (function() {
            const nextButton = document.querySelector('.next-button');
            if (nextButton) {
                nextButton.click();
                return true;
            }
            return false;
        })();
        """
    }
    
    static func previousTrackScript() -> String {
        """
        (function() {
            const prevButton = document.querySelector('.previous-button');
            if (prevButton) {
                prevButton.click();
                return true;
            }
            return false;
        })();
        """
    }
    
    static func setVolumeScript(volume: Float) -> String {
        """
        (function() {
            const video = document.querySelector('video');
            if (video) {
                video.volume = \(volume);
                return true;
            }
            return false;
        })();
        """
    }
    
    static func toggleShuffleScript() -> String {
        """
        (function() {
            const shuffleButton = document.querySelector('#shuffle-button');
            if (shuffleButton) {
                shuffleButton.click();
                return true;
            }
            return false;
        })();
        """
    }
    
    static func toggleRepeatScript() -> String {
        """
        (function() {
            const repeatButton = document.querySelector('#repeat-button');
            if (repeatButton) {
                repeatButton.click();
                return true;
            }
            return false;
        })();
        """
    }
    
    static func thumbsUpScript() -> String {
        """
        (function() {
            const bar = document.querySelector('ytmusic-player-bar');
            if (!bar) { return false; }
            let btn = bar.querySelector('#button-shape-like button');
            if (!btn) {
                const renderer = bar.querySelector('ytmusic-like-button-renderer');
                if (renderer) {
                    btn = renderer.querySelector('yt-button-shape:first-of-type button, button[aria-label*="like" i]:not([aria-label*="dislike" i])');
                }
            }
            if (btn) { btn.click(); return true; }
            return false;
        })();
        """
    }

    static func thumbsDownScript() -> String {
        """
        (function() {
            const bar = document.querySelector('ytmusic-player-bar');
            if (!bar) { return false; }
            let btn = bar.querySelector('#button-shape-dislike button');
            if (!btn) {
                const renderer = bar.querySelector('ytmusic-like-button-renderer');
                if (renderer) {
                    btn = renderer.querySelector('button[aria-label*="dislike" i]');
                }
            }
            if (btn) { btn.click(); return true; }
            return false;
        })();
        """
    }

    /// Toggles the current track's library membership by sending YT Music's own
    /// library-edit feedback request — no menu UI, no clicks, no rendering — so it
    /// works while the window is minimized/occluded (the NotchNest case).
    /// `currentlyInLibrary` is UYTM's known state; it selects the directional
    /// endpoint so repeated toggles stay correct even if the cached menu text is
    /// stale. Returns "added" / "removed" (the new state) or "nochange".
    static func toggleLibraryScript(currentlyInLibrary: Bool) -> String {
        let want = currentlyInLibrary ? "remove from library" : "save to library"
        let newState = currentlyInLibrary ? "removed" : "added"
        return """
        (function() {
            var bar = document.querySelector('ytmusic-player-bar');
            var mr = bar && bar.querySelector('ytmusic-menu-renderer');
            if (!mr) { return 'nochange'; }

            // Find the track's library toggle in the player-bar menu DATA (current
            // track, render-free). BFS is bounded and fully guarded.
            var roots = [mr.data, mr.__data].filter(Boolean);
            var q = roots.slice(), visited = [], count = 0, item = null;
            while (q.length && count < 6000) {
                var o = q.shift(); count++;
                if (!o || typeof o !== 'object' || visited.indexOf(o) !== -1) { continue; }
                visited.push(o);
                try {
                    var dt = o.defaultText && o.defaultText.runs && o.defaultText.runs[0] && o.defaultText.runs[0].text;
                    var tt = o.toggledText && o.toggledText.runs && o.toggledText.runs[0] && o.toggledText.runs[0].text;
                    if (((dt && /^(save to|remove from) library$/i.test(dt)) ||
                         (tt && /^(save to|remove from) library$/i.test(tt))) &&
                        (o.defaultServiceEndpoint || o.toggledServiceEndpoint)) { item = o; break; }
                } catch(e){}
                for (var k in o) { try { var v = o[k]; if (v && typeof v === 'object') { q.push(v); } } catch(e){} }
            }
            if (!item) { return 'nochange'; }

            // Pick the endpoint whose paired label matches the action we WANT, so the
            // direction is right even if the cached menu text lags actual state.
            function txt(r){ return ((r && r.runs && r.runs[0] && r.runs[0].text) || '').toLowerCase(); }
            var want = '\(want)';
            var ep = null;
            if (txt(item.defaultText) === want) { ep = item.defaultServiceEndpoint; }
            else if (txt(item.toggledText) === want) { ep = item.toggledServiceEndpoint; }
            if (!ep || !(ep.feedbackEndpoint && ep.feedbackEndpoint.feedbackToken)) {
                ep = item.defaultServiceEndpoint || item.toggledServiceEndpoint;
            }
            var token = ep && ep.feedbackEndpoint && ep.feedbackEndpoint.feedbackToken;
            if (!token) { return 'nochange'; }

            // Send it the way YT Music does internally: POST the feedbackToken to
            // /youtubei/v1/feedback with the InnerTube key+context and a SAPISIDHASH
            // Authorization header (computed from the SAPISID cookie).
            function sapisidHash(){
                var m = document.cookie.match(/(?:^|;\\s*)SAPISID=([^;]+)/) || document.cookie.match(/(?:^|;\\s*)__Secure-3PAPISID=([^;]+)/);
                if (!m) { return Promise.resolve(null); }
                var sapisid = m[1], origin = 'https://music.youtube.com', ts = Math.floor(Date.now()/1000);
                return crypto.subtle.digest('SHA-1', new TextEncoder().encode(ts+' '+sapisid+' '+origin)).then(function(buf){
                    var hex = Array.prototype.map.call(new Uint8Array(buf), function(b){ return ('0'+b.toString(16)).slice(-2); }).join('');
                    return 'SAPISIDHASH '+ts+'_'+hex;
                });
            }
            var key = (window.ytcfg && ytcfg.get && ytcfg.get('INNERTUBE_API_KEY')) || '';
            var apictx = (window.ytcfg && ytcfg.get && ytcfg.get('INNERTUBE_CONTEXT')) || {};
            sapisidHash().then(function(auth){
                var headers = { 'Content-Type':'application/json', 'X-Origin':'https://music.youtube.com' };
                if (auth) { headers['Authorization'] = auth; }
                return fetch('/youtubei/v1/feedback?key='+key+'&prettyPrint=false', {
                    method:'POST', credentials:'include', headers:headers,
                    body: JSON.stringify({ context: apictx, feedbackTokens: [token] })
                });
            }).catch(function(){});
            return '\(newState)';
        })();
        """
    }

    static func seekToScript(time: TimeInterval) -> String {
        """
        (function() {
            const video = document.querySelector('video');
            if (video) {
                video.currentTime = \(time);
                return true;
            }
            return false;
        })();
        """
    }
    
    // User script to auto-inject on page load
    @MainActor static func createAutoUpdateUserScript() -> WKUserScript {
        let script = """
        (function() {
            // Notify native app when track changes
            const video = document.querySelector('video');
            if (video) {
                video.addEventListener('play', function() {
                    window.webkit.messageHandlers.trackChanged.postMessage('play');
                });
                video.addEventListener('pause', function() {
                    window.webkit.messageHandlers.trackChanged.postMessage('pause');
                });
            }
            
            // Observe DOM changes for track changes
            const observer = new MutationObserver(function(mutations) {
                const titleElement = document.querySelector('.title.style-scope.ytmusic-player-bar');
                if (titleElement) {
                    window.webkit.messageHandlers.trackChanged.postMessage('trackchange');
                }
            });
            
            setTimeout(function() {
                const playerBar = document.querySelector('ytmusic-player-bar');
                if (playerBar) {
                    observer.observe(playerBar, { childList: true, subtree: true });
                }
            }, 1000);
        })();
        """
        
        return WKUserScript(
            source: script,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
    }
}
