# Integrating with Ultimate YTM Desktop

Ultimate YTM (UYTM) exposes a lightweight, dependency-free integration surface so
other apps on the same Mac can **observe playback state** and **send playback
commands** — the same mechanism the [NotchNest](https://github.com/) companion uses.
If you're building a notch widget, a Stream Deck plugin, a menu-bar mini-player, an
automation, or anything else that wants to react to or control UYTM, this is the
contract.

## How it works

All communication is over **`DistributedNotificationCenter`** — macOS's cross-process
notification bus. No entitlements, no sockets, no helper process; it works as long as
both apps run in the same user session. Subscribe/post on
`DistributedNotificationCenter.default()`.

Because `DistributedNotificationCenter` coalesces and drops non-property-list values,
**every `userInfo` value is a `String`.** Numbers are decimal strings; booleans are
`"1"`/`"0"`. Always post with `deliverImmediately: true`.

- UYTM bundle id: `com.ultimateytm.app`
- Notification names are global (not object-scoped) — register with the exact names below.

---

## A. Playback updates — UYTM → your app

**Name:** `com.ultimateytm.app.playbackUpdate`

UYTM posts this on track change, play/pause, seek, and roughly every second while
playing (so elapsed time stays current). `userInfo` (all `String`):

| Key | Value |
|-----|-------|
| `title` | Track title |
| `artist` | Artist |
| `album` | Album (may be empty) |
| `duration` | Seconds, e.g. `"213.0"` |
| `elapsed` | Seconds, e.g. `"41.2"` |
| `isPlaying` | `"1"` / `"0"` |
| `artworkPath` | Absolute path to a PNG in the temp dir, or `""` |
| `trackID` | Stable video id for dedupe, or `""` |
| `rating` | `"up"` / `"down"` / `""` (current thumbs rating) |
| `inLibrary` | `"1"` / `"0"` (track saved in your library) |

Artwork is written to a file (`NSTemporaryDirectory()/ultimateytm-artwork.png`) and
passed by path — read it with `NSImage(contentsOfFile:)`. Avoid expecting base64 in
`userInfo`.

### Example (Swift)

```swift
import Foundation

let center = DistributedNotificationCenter.default()
center.addObserver(forName: .init("com.ultimateytm.app.playbackUpdate"),
                   object: nil, queue: .main) { note in
    let u = note.userInfo ?? [:]
    let title     = u["title"]     as? String ?? ""
    let isPlaying = (u["isPlaying"] as? String) == "1"
    let inLibrary = (u["inLibrary"] as? String) == "1"
    print("\(title) — playing:\(isPlaying) inLibrary:\(inLibrary)")
}
```

---

## B. Remote commands — your app → UYTM

**Name:** `com.ultimateytm.app.remoteCommand`

`userInfo`:

| Key | Value |
|-----|-------|
| `command` | one of: `playpause` `play` `pause` `next` `previous` `seek` `thumbsUp` `thumbsDown` `toggleLibrary` |
| `value` | for `seek`: target seconds as a `String`; otherwise `""` |

`thumbsUp`/`thumbsDown` toggle the rating (re-issuing the same one clears it).
`toggleLibrary` saves/removes the current track. After acting on `thumbsUp`,
`thumbsDown`, or `toggleLibrary`, UYTM immediately re-broadcasts (A) so `rating` /
`inLibrary` reflect the new state — typically within ~1 second.

These work while UYTM is in the background or minimized.

### Example (Swift)

```swift
DistributedNotificationCenter.default().postNotificationName(
    .init("com.ultimateytm.app.remoteCommand"),
    object: nil,
    userInfo: ["command": "toggleLibrary", "value": ""],
    deliverImmediately: true
)
```

---

## C. State request — your app → UYTM

**Name:** `com.ultimateytm.app.requestState`

No `userInfo`. On receipt, UYTM immediately re-broadcasts the current state via (A).
Post this once at launch so your UI shows the current track without waiting for the
next playback event.

```swift
DistributedNotificationCenter.default().postNotificationName(
    .init("com.ultimateytm.app.requestState"), object: nil,
    userInfo: nil, deliverImmediately: true)
```

---

## Notes & caveats

- UYTM must be running. There's no launch-on-demand; gate your UI on having received a
  recent `playbackUpdate`.
- `trackID` is derived from the artwork URL when possible and may be `""` for some
  sources — don't rely on it as a guaranteed primary key.
- `inLibrary` is read from YouTube Music's own data and reflects the **logged-in user's
  library**. Note that YouTube Music itself couples some actions (e.g. a liked song is
  kept in your library), so `rating` and `inLibrary` can move together.
- Values are strings by design — parse defensively and treat missing keys as unknown.
- This is an unofficial integration surface for a third-party app; names and fields may
  evolve. Pin to a UYTM version if you need stability.
