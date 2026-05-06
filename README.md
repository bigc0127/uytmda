# Ultimate YTM Desktop App

A native macOS desktop application for YouTube Music built with Swift, featuring a stunning Liquid Glass UI and advanced media controls.

> **Unofficial / third-party project.** Not affiliated with, endorsed by, or sponsored by Google LLC or YouTube. "YouTube Music" is a trademark of Google LLC. See [DISCLAIMER.md](DISCLAIMER.md) for details.

## Features

### 🎨 Liquid Glass UI
- Beautiful translucent frosted glass window design
- Modern macOS 26 design language
- Smooth animations and transitions
- Adaptive to light/dark mode

### 🎵 Advanced Media Controls
- **System Media Controls**: Full integration with macOS media keys (F7, F8, F9)
- **Now Playing Integration**: Display current track in Control Center and Lock Screen
- **Global Keyboard Shortcuts**: Control playback from anywhere
  - Play/Pause: `⌘⇧Space`
  - Next Track: `⌘⇧→`
  - Previous Track: `⌘⇧←`

### 🪟 Window Management
- **Main Window**: Full YouTube Music web interface with native integration
- **Mini Player**: Compact always-on-top player with essential controls
- **Window State Persistence**: Remembers size and position
- **Multi-Space Support**: Works across all macOS Spaces

### 🔔 Notifications
- Native macOS notifications for track changes
- Album artwork in notifications
- Customizable notification settings

### ⚙️ Preferences
- Toggle notifications
- Configure mini player behavior
- View keyboard shortcuts
- Manage app settings

### 🎛️ Playback Features
- Play/Pause control
- Next/Previous track
- Shuffle toggle
- Repeat mode toggle
- Volume control
- Seek/scrubbing support

### 📋 Menu Bar & Dock Integration
- Custom Playback menu
- Dock menu with quick controls
- Current track display in window title

## Requirements

- macOS 26.0 or later
- Xcode 26.0 or later
- Swift 6.0
- Apple Silicon (arm64)

## Building

### Using Xcode

1. Open `UltimateYTM.xcodeproj` in Xcode
2. Select your Mac as the destination
3. Build and run (⌘R)

### Using Command Line

```bash
# Build Debug
xcodebuild -project UltimateYTM.xcodeproj -scheme UltimateYTM -destination "platform=macOS,arch=arm64" -configuration Debug build

# Build Release
xcodebuild -project UltimateYTM.xcodeproj -scheme UltimateYTM -destination "platform=macOS,arch=arm64" -configuration Release build
```

## Permissions

The app requires the following permissions:

- **Network Access**: To load YouTube Music
- **Notifications**: To show track change notifications
- **Accessibility** (Optional): For global keyboard shortcuts

## Project Structure

```
UltimateYTM/
├── AppDelegate.swift              # Main application coordinator
├── Models/
│   ├── TrackInfo.swift            # Track metadata model
│   └── AppSettings.swift          # User preferences and settings
├── Views/
│   ├── LiquidGlassWindow.swift    # Custom window with glass effect
│   ├── MainWindowController.swift # Main app window
│   ├── MiniPlayerController.swift # Compact player window
│   └── PreferencesWindowController.swift # Settings window
├── Managers/
│   ├── WebViewManager.swift       # YouTube Music web view handler
│   ├── MediaPlayerManager.swift   # System media controls
│   ├── KeyboardShortcutManager.swift # Global shortcuts
│   └── NotificationManager.swift  # Native notifications
├── Utilities/
│   └── JavaScriptBridge.swift     # JS injection for web control
└── Resources/
    └── Assets.xcassets            # App icons and assets
```

## Architecture

The app uses a clean architecture with separation of concerns:

- **WebView Manager**: Handles YouTube Music web interface and JavaScript communication
- **Media Player Manager**: Integrates with macOS media controls (MediaPlayer framework)
- **Keyboard Shortcut Manager**: Manages global keyboard shortcuts via CGEvent tap
- **Notification Manager**: Handles native macOS notifications
- **Settings Manager**: Persists user preferences via UserDefaults
- **Window Controllers**: Manage UI and user interactions

## JavaScript Integration

The app injects JavaScript into the YouTube Music web player to:
- Extract track metadata (title, artist, album, artwork)
- Control playback (play/pause, next, previous)
- Monitor player state changes
- Adjust volume and playback settings

## Known Limitations

- Requires active internet connection
- Depends on YouTube Music web interface (may break if YouTube changes their HTML structure)
- Global keyboard shortcuts require Accessibility permissions
- Album artwork download requires network access

## Future Enhancements

- [ ] Custom app icon
- [ ] Lyrics support
- [ ] Queue management
- [ ] Last.fm scrobbling
- [ ] Discord Rich Presence
- [ ] Audio equalizer
- [ ] Custom themes
- [ ] Touch Bar support (for older Macs)

## Troubleshooting

### Global shortcuts not working
1. Go to System Settings → Privacy & Security → Accessibility
2. Add Ultimate YTM to the list
3. Restart the app

### No sound
- Check macOS Sound settings
- Ensure YouTube Music has permission to play audio
- Verify network connection

### Liquid Glass effect not visible
- Ensure you're running macOS 26 or later
- Check Display settings for transparency effects
- Try toggling between light/dark mode

## License

Released under the [GNU Affero General Public License v3.0](LICENSE) (AGPL-3.0). Free and open source. You may use, modify, and redistribute this software under the terms of the AGPL — derivative works and network-deployed versions must be released under the same license with source code available. Provided as-is, no warranty.

Copyright (c) 2026 Connor Needling

## Acknowledgments

- Built with Swift and native macOS frameworks
- Uses WKWebView for YouTube Music web interface
- Inspired by modern macOS design principles
- YouTube Music is a trademark of Google LLC
