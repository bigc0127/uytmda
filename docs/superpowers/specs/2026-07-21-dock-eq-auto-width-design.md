# Dock Equalizer Auto Width — macOS 27 Design

**Date:** 2026-07-21
**Status:** Approved

## Goal

When the rainbow Dock equalizer's width is set to Auto (`equalizerWidthOverride == 0`),
the overlay should match the visible Dock pill exactly and **grow/shrink live as apps
launch and quit**, tracking the Dock's own resize animation.

## Background / findings (measured on macOS 27 beta 4, build 26A5388g)

- No new public API in the macOS 27 SDK exposes Dock geometry (checked AppKit headers;
  only `NSScreen.touchCapabilities` is new; `NSDockTile` unchanged).
- `CGWindowListCopyWindowInfo` is a dead end: the Dock renders the pill inside a single
  full-screen window, so window bounds don't describe the pill.
- **Accessibility works and is exact**: the Dock app's `AXList` element frame equals the
  visible pill (measured 1450×76). The app already has this code path
  (`dockListFrameViaAccessibility`) but never prompts for permission, so
  `AXIsProcessTrusted()` is false for virtually every user and the path is dead in
  practice.
- The plist-based estimate is wrong by ~12.5% (1268 vs 1450) because it:
  - misses running-but-unpinned apps (Dock shows them; plist only has persistent items),
  - misses separators (27 pt each), and
  - uses stale calibration constants.
- Measured beta 4 geometry (magnification off; rest state):
  - item pitch = `tilesize + 4` (tilesize 56 → 60 pt per item)
  - separator = 27 pt
  - edge padding = 8 pt per side (16 total)
  - Formula `(tilesize+4)×items + 27×separators + 16` reproduces the measured pill
    width exactly (23 items + 2 separators → 1450).

## Design

### 1. Accessibility prompt (exact path)

- When the equalizer is enabled and width is Auto, call
  `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` once.
- Gate with a UserDefaults flag so the system prompt is triggered at most once ever;
  subsequent launches never nag. (If the user later grants permission manually, the
  existing polling picks it up — no restart needed.)
- Preferences: one caption line under the width slider: Auto uses Accessibility for
  exact pill size when granted.

### 2. Improved estimate (fallback when AX not granted)

Pure function, unit-testable:

```
estimateDockPillWidth(tilesize, appItems, otherItems, hasUnpinnedSection, showsTrash…)
width = (tilesize + 4) × itemCount + 27 × separatorCount + 16
```

- `itemCount` = union of persistent-app bundle IDs (plist) and running apps with
  `activationPolicy == .regular` (NSWorkspace), + persistent-others, + trash,
  + recents when `show-recents` is on.
- `separatorCount`: +1 when the running-unpinned section is non-empty, +1 when the
  others/trash section is present (matches observed AX layout: two separators).
- Magnification is ignored (rest-state geometry is unaffected).

### 3. Live resize tracking

- Keep the existing 1 s dock-tracking timer as the steady-state poll (it re-evaluates
  AX trust and frame every tick).
- Subscribe to `NSWorkspace.didLaunchApplicationNotification` and
  `didTerminateApplicationNotification`; on either, burst-poll the frame at 10 Hz for
  ~2 s so the overlay follows the Dock's own resize animation instead of jumping on
  the next 1 s tick.

### 4. Unchanged

- Priority order stays: explicit override → AX exact → estimate → full-width fallback.
- Plist unreadable → full width, as today.
- Explicit pixel override behavior untouched.

## Error handling

- AX denied or AX query fails → estimate.
- Estimate inputs missing (no tilesize, empty plist) → full-width fallback.
- All failures silent; the equalizer never disappears because of geometry errors.

## Testing

- Unit-test `estimateDockPillWidth` against the measured beta 4 ground truth
  (tilesize 56, 23 items, 2 separators → 1450) and edge cases (no others, recents on).
- Manual: toggle Auto, grant/deny AX, launch/quit an app and watch the pill track the
  Dock resize.
