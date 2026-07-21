# Dock EQ Auto Width (macOS 27) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When equalizer width is Auto, the Dock overlay matches the visible Dock pill exactly and grows/shrinks live as apps launch/quit.

**Architecture:** Three layers. (1) A new pure `DockPillEstimator` computes pill width from Dock plist data plus running apps, calibrated on macOS 27 beta 4. (2) `MainWindowController` prompts once for Accessibility (exact `AXList` frame path already exists) and uses the estimator as fallback. (3) NSWorkspace launch/terminate notifications trigger a 10 Hz × 2 s burst poll so the overlay tracks the Dock's resize animation.

**Tech Stack:** Swift 6 / AppKit, no new dependencies. Tests run via `swiftc` standalone binary (project has no XCTest target).

## Global Constraints

- Target macOS 27.0; Swift 6 strict concurrency (`MainActor.assumeIsolated` in Timer callbacks — see `RainbowEqualizerView.startTicking` for the house pattern).
- Priority order must remain: explicit override → AX exact → estimate → full-width fallback.
- All geometry failures silent; the equalizer must never disappear due to estimate errors.
- Calibration constants (measured beta 4, build 26A5388g): item pitch = tilesize + 4; separator = 27 pt; edge padding = 16 pt total. Ground truth: tilesize 56, 23 items, 2 separators → 1450 pt.
- Spec: `docs/superpowers/specs/2026-07-21-dock-eq-auto-width-design.md`.

---

### Task 1: DockPillEstimator (pure, tested)

**Files:**
- Create: `UltimateYTM/Utilities/DockPillEstimator.swift`
- Create: `Tests/DockPillEstimatorTests.swift` (standalone runner, not in app target)
- Modify: `UltimateYTM.xcodeproj/project.pbxproj` (register new source file)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `DockPillEstimator.pillWidth(tilesize: CGFloat, itemCount: Int, separatorCount: Int) -> CGFloat`
  - `DockPillEstimator.counts(persistentAppIDs: [String], otherItemCount: Int, recentAppIDs: [String], runningAppIDs: [String]) -> (items: Int, separators: Int)`

- [ ] **Step 1: Write the failing test**

Create `Tests/DockPillEstimatorTests.swift`:

```swift
// Standalone test runner (no XCTest target in project).
// Run: swiftc UltimateYTM/Utilities/DockPillEstimator.swift Tests/DockPillEstimatorTests.swift -o /tmp/dpe-test && /tmp/dpe-test

import CoreGraphics
import Foundation

var failures = 0
func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

// Ground truth measured on macOS 27 beta 4 (build 26A5388g):
// tilesize 56, 23 icon items, 2 separators -> AXList width 1450.
expect(DockPillEstimator.pillWidth(tilesize: 56, itemCount: 23, separatorCount: 2) == 1450,
       "beta4 ground-truth width")
expect(DockPillEstimator.pillWidth(tilesize: 0, itemCount: 23, separatorCount: 2) == 0,
       "zero tilesize -> 0")
expect(DockPillEstimator.pillWidth(tilesize: 56, itemCount: 0, separatorCount: 0) == 0,
       "zero items -> 0")

// Measured layout: 15 pinned apps (Finder not pinned), 5 folders, 1 running unpinned
// app, recents shown but empty -> 16 apps + 1 middle + 6 others = 23 items, 2 separators.
let pinned = (1...15).map { "com.pinned.app\($0)" }
let c1 = DockPillEstimator.counts(
    persistentAppIDs: pinned,
    otherItemCount: 5,
    recentAppIDs: [],
    runningAppIDs: pinned + ["com.apple.finder", "com.example.unpinned"])
expect(c1.items == 23 && c1.separators == 2, "measured beta4 dock layout")

// Minimal dock: 1 pinned app, nothing else running but Finder, no folders.
// -> pinned + Finder + Trash = 3 items, only the trailing separator.
let c2 = DockPillEstimator.counts(
    persistentAppIDs: ["com.pinned.app1"],
    otherItemCount: 0,
    recentAppIDs: [],
    runningAppIDs: ["com.pinned.app1", "com.apple.finder"])
expect(c2.items == 3 && c2.separators == 1, "minimal dock, no middle section")

// Recents and running-unpinned dedupe into one middle section.
let c3 = DockPillEstimator.counts(
    persistentAppIDs: ["com.pinned.app1"],
    otherItemCount: 2,
    recentAppIDs: ["com.example.recent", "com.example.both"],
    runningAppIDs: ["com.apple.finder", "com.example.both"])
expect(c3.items == 2 + 2 + 3 && c3.separators == 2, "recents/running dedupe")

// Finder pinned explicitly must not double-count.
let c4 = DockPillEstimator.counts(
    persistentAppIDs: ["com.apple.finder", "com.pinned.app1"],
    otherItemCount: 0,
    recentAppIDs: [],
    runningAppIDs: ["com.apple.finder"])
expect(c4.items == 3 && c4.separators == 1, "finder pinned not double-counted")

if failures > 0 { print("\(failures) FAILURES"); exit(1) }
print("ALL PASS")
```

- [ ] **Step 2: Run test to verify it fails**

Run (repo root):
```bash
mkdir -p Tests
swiftc UltimateYTM/Utilities/DockPillEstimator.swift Tests/DockPillEstimatorTests.swift -o /tmp/dpe-test && /tmp/dpe-test
```
Expected: FAIL — `error: ... DockPillEstimator.swift: No such file` (compile error).

- [ ] **Step 3: Write minimal implementation**

Create `UltimateYTM/Utilities/DockPillEstimator.swift` (include the project's standard AGPL header comment — copy the 15-line header from `UltimateYTM/Views/RainbowEqualizerView.swift`):

```swift
import CoreGraphics
import Foundation

/// Estimates the visible Dock pill width from Dock preferences plus the live set of
/// running apps — the no-permission fallback when Accessibility isn't granted.
/// Calibrated on macOS 27 beta 4 (rest state; magnification only affects hover, so it
/// is ignored): item pitch = tilesize + 4, separator = 27 pt, edge padding = 8 pt/side.
enum DockPillEstimator {

    /// Pure geometry: pill width for a tile size, icon-item count and separator count.
    static func pillWidth(tilesize: CGFloat, itemCount: Int, separatorCount: Int) -> CGFloat {
        guard tilesize > 0, itemCount > 0 else { return 0 }
        return (tilesize + 4) * CGFloat(itemCount) + 27 * CGFloat(separatorCount) + 16
    }

    /// Derives icon-item and separator counts from Dock plist content plus running apps.
    /// - persistentAppIDs: bundle IDs pinned in the Dock (plist `persistent-apps`)
    /// - otherItemCount: plist `persistent-others` count (folders/stacks)
    /// - recentAppIDs: plist `recent-apps` bundle IDs; pass [] when show-recents is off
    /// - runningAppIDs: bundle IDs of running apps with `.regular` activation policy
    static func counts(persistentAppIDs: [String],
                       otherItemCount: Int,
                       recentAppIDs: [String],
                       runningAppIDs: [String]) -> (items: Int, separators: Int) {
        let finderID = "com.apple.finder"
        let persistent = Set(persistentAppIDs)
        // Finder always occupies the leading slot whether or not it's pinned.
        let appSection = persistent.subtracting([finderID]).count + 1
        // Middle section: recents plus running-but-unpinned apps, deduped.
        let middle = Set(recentAppIDs).union(runningAppIDs)
            .subtracting(persistent)
            .subtracting([finderID])
            .count
        // Trailing section: folders/stacks plus Trash (always visible).
        let otherSection = otherItemCount + 1
        let separators = (middle > 0 ? 1 : 0) + 1
        return (appSection + middle + otherSection, separators)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
swiftc UltimateYTM/Utilities/DockPillEstimator.swift Tests/DockPillEstimatorTests.swift -o /tmp/dpe-test && /tmp/dpe-test
```
Expected: 7 `PASS` lines then `ALL PASS`, exit 0.

- [ ] **Step 5: Register file in Xcode project**

Edit `UltimateYTM.xcodeproj/project.pbxproj` — four insertions, mirroring `JavaScriptBridge.swift`'s pattern (IDs must be unique; use `2A0000FA.../2A0000FB...`):

1. PBXBuildFile section (near line 22):
```
		2A0000FA000000000000000A /* DockPillEstimator.swift in Sources */ = {isa = PBXBuildFile; fileRef = 2A0000FB000000000000000A /* DockPillEstimator.swift */; };
```
2. PBXFileReference section (near line 47):
```
		2A0000FB000000000000000A /* DockPillEstimator.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DockPillEstimator.swift; sourceTree = "<group>"; };
```
3. Utilities group children (near line 147, next to `JavaScriptBridge.swift` file-ref line):
```
				2A0000FB000000000000000A /* DockPillEstimator.swift */,
```
4. Sources build phase (near line 240):
```
				2A0000FA000000000000000A /* DockPillEstimator.swift in Sources */,
```

Verify: `xcodebuild -project UltimateYTM.xcodeproj -scheme UltimateYTM build` → `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add UltimateYTM/Utilities/DockPillEstimator.swift Tests/DockPillEstimatorTests.swift UltimateYTM.xcodeproj/project.pbxproj
git commit -m "feat: dock pill width estimator calibrated for macOS 27"
```

---

### Task 2: Wire estimator + Accessibility prompt

**Files:**
- Modify: `UltimateYTM/Views/MainWindowController.swift:123-132` (`installDockEqualizerOverlay`), `:232-250` (`dockFrameFromDefaults`)
- Modify: `UltimateYTM/Models/AppSettings.swift:27-46` (Keys), add accessor after line 119
- Modify: `UltimateYTM/Views/PreferencesWindowController.swift:95` (caption)

**Interfaces:**
- Consumes: `DockPillEstimator.pillWidth(tilesize:itemCount:separatorCount:)`, `DockPillEstimator.counts(persistentAppIDs:otherItemCount:recentAppIDs:runningAppIDs:)` from Task 1.
- Produces: `AppSettings.shared.didPromptForAccessibility: Bool` (used within this task only).

- [ ] **Step 1: AppSettings — persisted prompt flag**

In `AppSettings.swift` `Keys` enum add:
```swift
        static let didPromptForAccessibility = "didPromptForAccessibility"
```
After `skippedUpdateVersion` property (line 119) add:
```swift
    /// Whether the one-time Accessibility permission prompt has been shown.
    /// Not @Published: nothing observes it and it must not trigger objectWillChange.
    var didPromptForAccessibility: Bool {
        get { defaults.bool(forKey: Keys.didPromptForAccessibility) }
        set { defaults.set(newValue, forKey: Keys.didPromptForAccessibility) }
    }
```

- [ ] **Step 2: MainWindowController — one-time AX prompt**

In `installDockEqualizerOverlay()`, immediately after the `guard AppSettings.shared.showEqualizer else { ... }` block, insert:
```swift
        requestAccessibilityIfNeeded()
```
Add this method next to `dockListFrameViaAccessibility`:
```swift
    /// One-time system prompt for Accessibility so Auto width can read the exact Dock
    /// pill frame. The persisted flag means a decline is never nagged about again; if
    /// the user grants later in System Settings, the 1 s tracking timer picks it up.
    private func requestAccessibilityIfNeeded() {
        guard AppSettings.shared.equalizerWidthOverride == 0,
              !AXIsProcessTrusted(),
              !AppSettings.shared.didPromptForAccessibility else { return }
        AppSettings.shared.didPromptForAccessibility = true
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
```

- [ ] **Step 3: MainWindowController — estimator-backed fallback**

Replace the body of `dockFrameFromDefaults(on:dockHeight:)` (lines 232-250) with:
```swift
    /// Estimate the visible Dock pill bounds from `com.apple.dock` defaults plus the
    /// live set of running apps. macOS has no public API for the rendered geometry;
    /// constants are calibrated against macOS 27 beta 4 (see DockPillEstimator).
    private func dockFrameFromDefaults(on screen: NSScreen, dockHeight: CGFloat) -> NSRect? {
        guard let plist = readDockPlist(), !plist.isEmpty else { return nil }
        guard (plist["orientation"] as? String ?? "bottom") == "bottom" else { return nil }
        guard let tilesize = (plist["tilesize"] as? Double).flatMap({ CGFloat($0) }), tilesize > 0 else { return nil }

        let persistentIDs = Self.bundleIDs(inTiles: plist["persistent-apps"])
        let otherCount = (plist["persistent-others"] as? [Any])?.count ?? 0
        let showRecents = (plist["show-recents"] as? Bool) ?? true
        let recentIDs = showRecents ? Self.bundleIDs(inTiles: plist["recent-apps"]) : []
        let runningIDs = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier)

        let (items, separators) = DockPillEstimator.counts(
            persistentAppIDs: persistentIDs,
            otherItemCount: otherCount,
            recentAppIDs: recentIDs,
            runningAppIDs: runningIDs)
        let estimatedWidth = DockPillEstimator.pillWidth(
            tilesize: tilesize, itemCount: items, separatorCount: separators)
        guard estimatedWidth > 0 else { return nil }

        let pillHeight = dockHeight - 6
        let width = min(estimatedWidth, screen.frame.width - 80)
        let x = screen.frame.minX + (screen.frame.width - width) / 2
        let y = screen.frame.minY + (dockHeight - pillHeight) / 2
        return NSRect(x: x, y: y, width: width, height: pillHeight)
    }

    private static func bundleIDs(inTiles value: Any?) -> [String] {
        guard let tiles = value as? [[String: Any]] else { return [] }
        return tiles.compactMap {
            ($0["tile-data"] as? [String: Any])?["bundle-identifier"] as? String
        }
    }
```

- [ ] **Step 4: Preferences caption**

In `PreferencesWindowController.swift:95` replace:
```swift
                        Text("Slide right to dial in your Dock pill width. Set to 0 (Auto) for full-width fallback.")
```
with:
```swift
                        Text("Slide right to dial in your Dock pill width. Set to 0 (Auto) to match the Dock automatically — grant Accessibility for exact sizing.")
```

- [ ] **Step 5: Build**

Run: `xcodebuild -project UltimateYTM.xcodeproj -scheme UltimateYTM build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add UltimateYTM/Views/MainWindowController.swift UltimateYTM/Models/AppSettings.swift UltimateYTM/Views/PreferencesWindowController.swift
git commit -m "feat: exact dock pill via one-time AX prompt, running-app-aware estimate"
```

---

### Task 3: Live grow/shrink tracking

**Files:**
- Modify: `UltimateYTM/Views/MainWindowController.swift` — `observeSettings()` (line 114), `updateDockEqualizerFrame()` (line 187), `tearDownDockEqualizerOverlay()` (line 170), new burst-timer members.

**Interfaces:**
- Consumes: `updateDockEqualizerFrame()` (existing), `isDockPillFrame(_:screen:)` (existing).
- Produces: nothing new externally.

- [ ] **Step 1: Workspace notifications + burst poll**

Below `private var dockTrackingTimer: Timer?` add:
```swift
    private var dockBurstTimer: Timer?
```
In `observeSettings()` append:
```swift
        let wsCenter = NSWorkspace.shared.notificationCenter
        wsCenter.addObserver(self, selector: #selector(runningAppsChanged), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        wsCenter.addObserver(self, selector: #selector(runningAppsChanged), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
```
Add methods near `startDockTracking()`:
```swift
    @objc private func runningAppsChanged() {
        Task { @MainActor in self.burstTrackDockResize() }
    }

    /// Follow the Dock's own grow/shrink animation after an app launches or quits:
    /// re-read the pill frame at 10 Hz for 2 s, then fall back to the 1 s steady poll.
    private func burstTrackDockResize() {
        dockBurstTimer?.invalidate()
        var ticks = 0
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { t.invalidate(); return }
                ticks += 1
                self.updateDockEqualizerFrame()
                if ticks >= 20 {
                    t.invalidate()
                    if self.dockBurstTimer === t { self.dockBurstTimer = nil }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dockBurstTimer = timer
    }
```

- [ ] **Step 2: Keep corner radius correct while resizing**

In `updateDockEqualizerFrame()`, replace:
```swift
        if dockEqualizerWindow?.frame != frame {
            dockEqualizerWindow?.setFrame(frame, display: true)
        }
```
with:
```swift
        if dockEqualizerWindow?.frame != frame {
            dockEqualizerWindow?.setFrame(frame, display: true)
            if let screen = window?.screen ?? NSScreen.main {
                let isPill = isDockPillFrame(frame, screen: screen)
                dockEqualizerWindow?.contentView?.layer?.cornerRadius = isPill ? min(frame.height / 2, 24) : 0
            }
        }
```

- [ ] **Step 3: Teardown**

In `tearDownDockEqualizerOverlay()` after `dockTrackingTimer = nil` add:
```swift
        dockBurstTimer?.invalidate()
        dockBurstTimer = nil
```

- [ ] **Step 4: Build**

Run: `xcodebuild -project UltimateYTM.xcodeproj -scheme UltimateYTM build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Manual verification**

Launch the built app (`build/…/UltimateYTM.app` or via Xcode), play music, then:
1. Quit and relaunch some app (e.g. TextEdit) — EQ pill should track the Dock's resize within ~0.1 s granularity.
2. With AX denied: estimate width should visually match the pill (±a few px).
3. Grant Accessibility in System Settings while the app runs — within 1 s the frame snaps to exact.

- [ ] **Step 6: Commit**

```bash
git add UltimateYTM/Views/MainWindowController.swift
git commit -m "feat: dock EQ tracks dock resize live on app launch/quit"
```
