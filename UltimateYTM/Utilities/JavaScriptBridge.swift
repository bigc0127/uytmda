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
            if (artworkElement) {
                const bgImage = artworkElement.style.backgroundImage;
                if (bgImage) {
                    const match = bgImage.match(/url\\("(.+)"\\)/);
                    if (match && match[1]) {
                        artworkURL = match[1].split('=')[0] + '=w512-h512-l90-rj';
                    }
                }
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
            
            return {
                title: titleElement ? titleElement.textContent.trim() : '',
                artist: artistElement ? artistElement.textContent.trim() : '',
                album: albumElement ? albumElement.textContent.trim() : '',
                duration: video ? video.duration : 0,
                currentTime: video ? video.currentTime : 0,
                artworkURL: artworkURL,
                isPaused: video ? video.paused : true,
                isShuffled: shuffleButton ? shuffleButton.getAttribute('aria-pressed') === 'true' : false,
                repeatMode: repeatMode
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
