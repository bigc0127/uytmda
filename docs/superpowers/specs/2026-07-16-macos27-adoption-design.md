# UltimateYTM — macOS 27 ("Golden Gate") Adoption

**Date:** 2026-07-16
**Author:** Connor Needling (+ Claude Code)
**Target version:** 1.0.6 → **1.1.0**
**Status:** Draft for review

## Goal

Move UltimateYTM from a macOS 26 target to a first-class macOS 27 app: raise the
deployment target, adopt the new **NowPlaying** framework for system media
integration, add a real audio-analysis-driven equalizer via **MusicUnderstanding**,
and modernize the window chrome to the real macOS 27 **Liquid Glass**
(`NSGlassEffectView`) with corner concentricity.

**This is not a rewrite.** The working WebView/auth/cookie/updater/NotchNest
architecture stays. We modernize four specific surfaces and ship through the
existing signed+notarized release + self-updater pipeline.

## Non-goals (explicitly out of scope)

- Foundation Models / Core AI features (scope creep for a music wrapper)
- Spatial Preview, App Intents view annotations
- Rewriting WebViewManager, AuthenticationManager, CookieBackupManager, UpdateManager
- Changing the DistributedNotificationCenter contract used by NotchNest integrations

## Verified environment (checked 2026-07-16)

- Xcode 27.0 (27A5218g) installed; `macosx27.0` SDK present.
- This machine runs macOS 27.0 → can build **and** runtime-test locally.
- `NowPlaying.framework` and `MusicUnderstanding.framework` exist on the SDK as
  pure-Swift modules (swiftinterface read, not guessed).
- `NSGlassEffectView`, `NSGlassEffectContainerView`, `NSViewCornerConfiguration.h`
  confirmed in the AppKit 27 headers.

## Work items

### 1. Deployment target bump (core, low risk)

- `MACOSX_DEPLOYMENT_TARGET` 26.0 → 27.0 in `project.pbxproj` (both configs).
- Keep `SWIFT_VERSION = 6.0`.
- Full build; triage every new deprecation/error. Fix or note each.

**Risk:** dropping macOS 26 users. Accepted — user's own laptop is on 27 and this
is a personal app. Noted in README.

### 2. NowPlaying framework adoption (core)

Replace the hand-rolled `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` usage in
`MediaPlayerManager.swift` with the new model, **incrementally and safely**.

Real API (from swiftinterface):
- Conform a manager-owned type to `MediaSessionRepresentable`:
  `var content: (any MediaContentRepresentable)?`, `var playbackSnapshot:
  MediaPlaybackSnapshot?`, `var commands: [MediaCommand]`.
- Use `MusicContent(...)` for now-playing metadata (title/artist/artwork/duration).
- Build commands from `MediaCommand.play/pause/togglePlayPause/next/previous/
  seekToPosition/changeShuffleMode/changeRepeatMode`, each wired to the existing
  JS bridge remote-control calls.
- Bonus: `MediaCommand.feedback(...)` maps cleanly onto the existing NotchNest
  thumbs-up/down + library toggle — surfaced to Control Center for free.
- Create `MediaSession(representable)`, call `requestToBecomeApplicationPrimary()`.
- `MediaSession` is `Observation.Observable`; mutate the representable's properties
  on the main actor and the session republishes.
- `MediaPlaybackSnapshot(state:elapsedTime:timestamp:)` for scrubbing/elapsed.

**Safety rule (hard):** media keys currently work. Adopt NowPlaying behind a build
that we runtime-verify (media keys + Control Center + lock screen) BEFORE deleting
the MP* path. If NowPlaying proves incomplete on macOS 27 for our use, keep MP* as
the backbone and treat this item as deferred — do not ship broken media keys.

**Artwork gotcha (regression watch):** the v1.0.3 crash was an `MPMediaItemArtwork`
handler inheriting `@MainActor` and being called off-main. NowPlaying's `Artwork`
is a different type; whatever async/callback path we use must not reintroduce
cross-actor isolation violations. Keep any framework-invoked closure `nonisolated`.

### 3. MusicUnderstanding equalizer (add-on)

`RainbowEqualizerView` currently animates on synthetic/among-tapped data. Drive it
with real on-device analysis.

Real API:
- `MusicUnderstandingSession(audioProvider:)` takes an
  `AsyncSequence<AVReadOnlyAudioPCMBuffer, Never>`. `AudioCaptureManager` already
  taps audio → adapt its output into that AsyncSequence.
- `analyze(for: [.rhythm, .loudness, .pace])` for one-shot, and the streaming
  `loudnessResults` AsyncSequence for realtime level → feed the bars.
- `.rhythm` gives beat/tempo → optional beat-synced pulse on the equalizer.

**Fallback:** if capturing YT Music's in-WebView audio into
`AVReadOnlyAudioPCMBuffer` proves not viable (permissions / no route), keep the
existing equalizer animation and log a clear note. The equalizer must never break.

**Permissions:** audio analysis is on-device (no network). Confirm no new
entitlement is required; if a usage-string/entitlement is needed, add it and note
the App Sandbox constraint (sandbox stays OFF per updater requirement).

### 4. Liquid Glass modernization (add-on)

`LiquidGlassWindow.swift` uses the old `NSVisualEffectView`. Upgrade to macOS 27:
- Replace/augment the background with `NSGlassEffectView` (+
  `NSGlassEffectContainerView` if grouping needed).
- Apply corner concentricity via `NSViewCornerConfiguration` so content corners
  nest correctly with the window.
- Keep `updateGlassMaterial`/`updateBlendingMode` public API working (or migrate
  callers in `AppSettings`/`PreferencesWindowController`) — check callers first.

**Also (menu regression):** macOS 27 `NSMenu` hides symbol images by default. Audit
menus (status item, main menu, mini player). Where an icon is meaningful, restore
it with `NSMenuItem.preferredImageVisibility`.

### 5. Build, verify, ship

- Build clean for `macosx27.0`.
- **Runtime-verify on this machine (macOS 27):** launch app, sign in still works
  (cookie restore), play a track, media keys, Control Center now-playing +
  commands + feedback, equalizer reacts, NotchNest bridge still broadcasts,
  window glass renders, menus show intended icons.
- Bump `MARKETING_VERSION` → 1.1.0.
- Sign + notarize + staple per `project_signing_release` flow (creds in keychain).
- Package `UltimateYTM-v1.1.0.zip`, create GitHub Release on `bigc0127/uytmda`
  with that zip asset (self-updater downloads first `.zip`).
- Confirm `UpdateManager` sees the new release.

## Rollback

Each work item is independent. If an add-on can't be made solid, ship core-only
(target bump + verified NowPlaying-or-MP* + menu fix) as 1.1.0 and defer the add-on.
Never ship a build with broken media keys, broken sign-in, or a broken updater.

## Success criteria

- Builds for macOS 27 SDK with no errors.
- All runtime-verify checks pass on the local macOS 27 machine.
- Signed+notarized+stapled 1.1.0 zip published as a GitHub Release.
- Self-updater on the user's laptop offers/installs 1.1.0.
