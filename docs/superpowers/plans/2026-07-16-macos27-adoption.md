# macOS 27 Adoption — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Ship UltimateYTM 1.1.0 targeting macOS 27, adopting NowPlaying, MusicUnderstanding EQ, and real Liquid Glass, then release via the self-updater.

**Architecture:** Modernize four surfaces in the existing app (no rewrite). MediaPlayerManager gains a NowPlaying-backed session (MP* kept as fallback until verified). AudioCaptureManager feeds MusicUnderstanding to drive RainbowEqualizerView. LiquidGlassWindow moves to NSGlassEffectView + corner concentricity. Menus fixed for macOS 27 symbol-image default.

**Tech Stack:** Swift 6, AppKit, MediaPlayer, NowPlaying (macOS 27), MusicUnderstanding (macOS 27), AVFAudio, WKWebView.

## Global Constraints

- `MACOSX_DEPLOYMENT_TARGET = 27.0`, `SWIFT_VERSION = 6.0`.
- App Sandbox stays **OFF** (self-updater swaps `/Applications/UltimateYTM.app`).
- No unit-test target exists → gate = clean build + runtime verification on this macOS 27 machine.
- Any closure handed to a framework that may call it off-main MUST be `nonisolated` (v1.0.3 crash class).
- Never ship broken: media keys, sign-in (cookie restore), or updater.
- DistributedNotificationCenter NotchNest contract unchanged.
- Verify gate command: `xcodebuild -project UltimateYTM.xcodeproj -scheme UltimateYTM -configuration Release build` (SDK macosx27.0).

---

### Task 1: Deployment target bump + baseline build

**Files:** Modify `UltimateYTM.xcodeproj/project.pbxproj` (all `MACOSX_DEPLOYMENT_TARGET`).

- [ ] Set every `MACOSX_DEPLOYMENT_TARGET = 26.0` → `27.0`.
- [ ] Build Release. Expected: succeeds (record any new deprecation warnings).
- [ ] Runtime smoke: launch build, confirm window opens + YT Music loads.
- [ ] Commit: `chore: target macOS 27.0`.

Gate: clean build + app launches.

---

### Task 2: NowPlaying framework session (additive, MP* retained)

**Files:** Modify `UltimateYTM/Managers/MediaPlayerManager.swift`. Check callers in `AppDelegate.swift`, `WebViewManager.swift` (onPlayPause/onNext/onPrevious/onSeek wiring) — signatures unchanged.

**Interfaces produced:** MediaPlayerManager keeps existing public API (`onPlayPause`, `onNext`, `onPrevious`, `onSeek`, `updateNowPlayingInfo(with:)`, `clearNowPlayingInfo()`). Internally adds a NowPlaying `MediaSession`.

- [ ] Add a `@MainActor` `NowPlayingRepresentable: MediaSessionRepresentable` holding `content`, `playbackSnapshot`, `commands`; build `commands` from `MediaCommand.play/pause/togglePlayPause/next/previous/seekToPosition` wired to the same `on*` callbacks.
- [ ] In `updateNowPlayingInfo(with:)`, ALSO populate `MusicContent(id:title:artistName:...artwork:duration:)` + `MediaPlaybackSnapshot(state:elapsedTime:)` and mutate the representable (Observable republishes). Artwork conversion via a `nonisolated` helper (no @MainActor capture).
- [ ] Lazily create `MediaSession(representable)` + `requestToBecomeApplicationPrimary()` on first update; guard `if #available(macOS 27, *)`.
- [ ] Keep all existing MP* code intact (dual-publish) this task.
- [ ] Build Release. Expected: succeeds.
- [ ] Runtime verify: play track → Control Center shows now-playing; play/pause/next/prev/seek from Control Center work; media keys work; **no crash on artwork**.
- [ ] Commit: `feat: NowPlaying framework session alongside MPNowPlayingInfoCenter`.

Gate: Control Center + media keys verified working. If NowPlaying misbehaves, keep MP* only and note deferral in spec.

---

### Task 3: Retire MP* duplication (only if Task 2 verified solid)

**Files:** Modify `MediaPlayerManager.swift`.

- [ ] Remove `MPRemoteCommandCenter`/`MPNowPlayingInfoCenter` paths; NowPlaying becomes sole backend. Keep `MPMediaItemArtwork` removal — use NowPlaying `Artwork`.
- [ ] Build + re-run Task 2 runtime verify.
- [ ] Commit: `refactor: NowPlaying as sole media backend`.

Gate: same as Task 2. If any regression, `git revert` this task, keep dual-publish.

---

### Task 4: macOS 27 menu symbol-image audit

**Files:** Modify wherever `NSMenuItem`s with images are built (`AppDelegate.swift` status item, `MainWindowController.swift`, `MiniPlayerController.swift`).

- [ ] Find menu items relying on SF Symbol images; set `.preferredImageVisibility = .visible` where the icon is meaningful.
- [ ] Build + launch; verify status-item + context menus show intended icons.
- [ ] Commit: `fix: restore menu symbol images on macOS 27`.

Gate: menus render icons as before.

---

### Task 5: MusicUnderstanding-driven equalizer

**Files:** Modify `UltimateYTM/Managers/AudioCaptureManager.swift`, `UltimateYTM/Views/RainbowEqualizerView.swift`. Possibly new `UltimateYTM/Managers/MusicAnalysisManager.swift`.

**Interfaces produced:** `MusicAnalysisManager` exposing a stream of normalized levels/beat the equalizer consumes.

- [ ] Adapt AudioCaptureManager tap output into an `AsyncSequence<AVReadOnlyAudioPCMBuffer, Never>`.
- [ ] `MusicUnderstandingSession(audioProvider:)`; consume `loudnessResults` (realtime) and/or `analyze(for: [.rhythm, .loudness])`; publish normalized values.
- [ ] Feed RainbowEqualizerView from real data; keep the existing animation as fallback if capture yields nothing.
- [ ] `if #available(macOS 27, *)` guard; wrap capture in permission/entitlement check.
- [ ] Build + runtime verify: play track, equalizer reacts to actual audio; if no audio route, animation still runs (no freeze/crash).
- [ ] Commit: `feat: MusicUnderstanding-driven equalizer with fallback`.

Gate: equalizer never breaks; reacts to audio when available.

---

### Task 6: Liquid Glass modernization

**Files:** Modify `UltimateYTM/Views/LiquidGlassWindow.swift`. Check callers of `updateGlassMaterial`/`updateBlendingMode` (`AppSettings.swift`, `PreferencesWindowController.swift`).

- [ ] Replace `NSVisualEffectView` background with `NSGlassEffectView` (under `if #available(macOS 27, *)`, else keep visual-effect fallback).
- [ ] Apply corner concentricity via `NSViewCornerConfiguration`.
- [ ] Preserve or migrate `updateGlassMaterial`/`updateBlendingMode` callers so preferences still work.
- [ ] Build + runtime verify: window renders glass; preferences material controls still function or are cleanly migrated.
- [ ] Commit: `feat: macOS 27 Liquid Glass window (NSGlassEffectView + corner concentricity)`.

Gate: window renders; no broken preferences.

---

### Task 7: Full runtime verification pass

- [ ] Fresh launch. Sign-in persists (cookie restore). Play track. Media keys + Control Center commands + feedback. Equalizer reacts. NotchNest bridge still broadcasts (check DistributedNotification). Window glass + menus correct.
- [ ] Record results in the spec's success-criteria checklist.

Gate: all checks pass. Any failure → fix or roll back that task; do not proceed to release.

---

### Task 8: Release 1.1.0

**Files:** `project.pbxproj` (`MARKETING_VERSION`).

- [ ] Bump `MARKETING_VERSION` 1.0.6 → 1.1.0. Commit `chore: 1.1.0`.
- [ ] Merge `macos27-adoption` → `main`.
- [ ] Run signed+notarized+stapled release flow (per `project_signing_release` memory; creds in keychain).
- [ ] Package `UltimateYTM-v1.1.0.zip`.
- [ ] Create GitHub Release on `bigc0127/uytmda` tag `v1.1.0` with the zip asset.
- [ ] Verify `UpdateManager` endpoint (`/repos/bigc0127/uytmda/releases/latest`) returns 1.1.0 with the zip.

Gate: release live, updater sees it.

---

### Task 9: Install on this laptop

- [ ] Trigger the in-app updater (or confirm it polls) so `/Applications/UltimateYTM.app` updates to 1.1.0.
- [ ] Launch installed 1.1.0, confirm version + sign-in intact.
