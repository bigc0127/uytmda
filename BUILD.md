# Build Instructions

## Quick Start

1. **Open the project in Xcode:**
   ```bash
   open UltimateYTM.xcodeproj
   ```

2. **Build and Run:**
   - Press `⌘R` to build and run
   - Or use the menu: Product → Run

3. **Build from Command Line:**
   ```bash
   xcodebuild -project UltimateYTM.xcodeproj \
     -scheme UltimateYTM \
     -destination "platform=macOS,arch=arm64" \
     -configuration Debug \
     build
   ```

## Build Status

✅ **BUILD SUCCEEDED** on first compilation!

## Project Statistics

- **Swift Files**: 12
- **Lines of Code**: ~1,658
- **Target**: macOS 26.0+
- **Architecture**: arm64 (Apple Silicon)
- **Language**: Swift 6.0

## Build Output Location

The built app will be at:
```
~/Library/Developer/Xcode/DerivedData/UltimateYTM-*/Build/Products/Debug/UltimateYTM.app
```

## Running the App

After building, you can run the app from:
1. Xcode (press `⌘R`)
2. The build products folder
3. Copy to Applications folder for permanent installation

## First Launch

On first launch, the app will:
1. Load YouTube Music web interface
2. Request notification permissions
3. Set up media control integration
4. Initialize global keyboard shortcuts (requires Accessibility permission)

## Permissions Required

### Automatic
- Network access (for YouTube Music)
- Notification display

### Manual (Optional)
To enable global keyboard shortcuts:
1. Go to System Settings → Privacy & Security → Accessibility
2. Add "Ultimate YTM" to the allowed apps
3. Restart the application

## Testing Features

### Basic Playback
1. Launch the app
2. Log in to YouTube Music
3. Play any song
4. Test media keys (F7, F8, F9)
5. Check Now Playing in Control Center

### Mini Player
- Press `⌘M` or View → Toggle Mini Player
- Drag to reposition
- Controls should sync with main window

### Notifications
- Play a song, then skip to next
- Notification should appear with track info and artwork

### Liquid Glass UI
- Toggle between Light/Dark mode in System Settings
- Window should show translucent frosted glass effect
- Vibrancy should adapt to system theme

## Troubleshooting

### Build Fails
- Ensure Xcode 26.0+ is installed
- Clean build folder: `⌘⇧K`
- Try: Product → Clean Build Folder

### App Won't Launch
- Check Console.app for crash logs
- Verify macOS version is 26.0+
- Ensure running on Apple Silicon Mac

### Media Keys Don't Work
- Check System Settings → Keyboard → Keyboard Shortcuts
- Ensure no conflicts with other apps
- Try restarting the app

### Global Shortcuts Don't Work
- Grant Accessibility permission (see above)
- Restart app after granting permission
- Check for conflicts in System Settings

## Development Mode

For development:
```bash
# Debug build (includes symbols, faster compile)
xcodebuild -configuration Debug build

# Release build (optimized, slower compile)  
xcodebuild -configuration Release build
```

## Next Steps

1. **Add Custom Icon**: Replace placeholder icon in Assets.xcassets
2. **Code Signing**: Configure signing in Xcode for distribution
3. **Testing**: Test all features thoroughly
4. **Customization**: Modify UI, add features, etc.

## Known Issues

- YouTube Music web interface may change, breaking JavaScript injection
- Global shortcuts require manual Accessibility permission grant
- First load may take a few seconds while YouTube Music initializes

## Support

For issues or questions, check:
- README.md for full documentation
- Console.app for runtime logs
- Xcode debugger for development issues
