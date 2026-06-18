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

            // Library: find the player-bar save/library toggle (same control
            // toggleLibraryScript() clicks) and read its on/off state. Signals are
            // checked most-authoritative first — aria-pressed, then the swapped
            // icon (library_add_check / saved), then the label phrasing — because a
            // static label can lag the real state. Guarded; defaults false.
            let inLibrary = false;
            try {
                const bar = document.querySelector('ytmusic-player-bar');
                if (bar) {
                    const ctrls = bar.querySelectorAll(
                        'button[aria-label], button[title], yt-button-shape button, ' +
                        'tp-yt-paper-icon-button[aria-label], [role="button"][aria-label]'
                    );
                    for (const c of ctrls) {
                        // Skip like/dislike — that is rating, not library.
                        if (c.closest('ytmusic-like-button-renderer')) { continue; }
                        const label = ((c.getAttribute('aria-label') || '') + ' ' +
                                       (c.getAttribute('title') || '')).toLowerCase();
                        if (!/library|save to|saved|added to/.test(label)) { continue; }
                        // Found the library control — resolve state.
                        const pressed = c.getAttribute('aria-pressed');
                        const icon = c.querySelector('yt-icon[icon], tp-yt-iron-icon[icon]');
                        const iconName = ((icon && icon.getAttribute('icon')) || '').toLowerCase();
                        if (pressed === 'true') { inLibrary = true; }
                        else if (pressed === 'false') { inLibrary = false; }
                        else if (/check|saved|library_add_check/.test(iconName)) { inLibrary = true; }
                        else if (/remove from library|added to library|in library|\\bsaved\\b/.test(label)) { inLibrary = true; }
                        else if (/save to library|add to library/.test(label)) { inLibrary = false; }
                        break;
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

    static func toggleLibraryScript() -> String {
        """
        (function() {
            const bar = document.querySelector('ytmusic-player-bar');
            if (!bar) { return false; }

            // 1. Direct library toggle in the player bar, if present.
            const directBtns = bar.querySelectorAll('button[aria-label], yt-button-shape button[aria-label]');
            for (const b of directBtns) {
                const label = (b.getAttribute('aria-label') || '');
                if (/library/i.test(label)) { b.click(); return true; }
            }

            // 2. Otherwise open the overflow ("...") menu and click the library item.
            const menuBtn = bar.querySelector('ytmusic-menu-renderer button, .menu button, button[aria-label*="more" i], yt-button-shape button[aria-label*="more" i]');
            if (!menuBtn) { return false; }
            menuBtn.click();

            // Menu renders into a popup container; query after a short delay.
            setTimeout(function() {
                const items = document.querySelectorAll('ytmusic-menu-popup-renderer tp-yt-paper-listbox ytmusic-menu-navigation-item-renderer, ytmusic-menu-popup-renderer ytmusic-menu-service-item-renderer, tp-yt-paper-item');
                for (const item of items) {
                    const text = (item.textContent || '') + ' ' + (item.getAttribute('aria-label') || '');
                    if (/library/i.test(text)) {
                        const clickable = item.querySelector('button') || item;
                        clickable.click();
                        return;
                    }
                }
                // Nothing matched: close the menu to avoid leaving it open.
                document.body.click();
            }, 250);
            return true;
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
