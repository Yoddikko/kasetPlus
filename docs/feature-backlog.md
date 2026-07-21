# Feature backlog — to review together

Notes for features discussed on 2026-07-21. Two were shipped on branch
`feature/telemetry-and-loc-tooling` (telemetry + localization tooling); the four
below need a decision, a credential, or changes to the playback core, so they're
written up rather than built blind.

---

## 1. Offline music downloads — needs design (touches playback core)

**Why it's not a quick win:** playback today runs through a hidden WebView
(YouTube/InnerTube stream). Playing a *local* file is a completely different
path (AVPlayer) that has to integrate with the queue, Now Playing, scrobbling,
and the mini-player. `YouTubeDownloadService` (yt-dlp) already fetches *video*
files, so the download half is mostly there; the missing half is a **local
playback engine + a "Downloaded" library**.

**Sketch:**
- Reuse `YouTubeDownloadService` to grab audio-only (`-f bestaudio`, m4a).
- Store under Application Support `Kaset/Downloads/<videoId>.m4a` + a small JSON
  index (title, artist, artwork, duration).
- Add an `AVPlayer`-backed source to `PlaybackArbiter` so a downloaded track
  plays locally instead of via WebView. This is the real work.
- A "Downloaded" section in the library; a download button on the track menu.

**Open questions for us:** ToS/legal stance (it's YouTube content); storage caps
/ eviction; do we download *audio* or reuse existing video files? Start with
"download audio + play locally for tracks already saved", skip playlists v1.

## 2. Menu-bar Now Playing — buildable, wants your eyes on the UX

Native path is `MenuBarExtra` (SwiftUI, macOS 13+). The player state already
exists (`NowPlayingManager`, `PlayerService+PlaybackControls`), so it's mostly
wiring: title/artist/artwork + play-pause / next / prev, and a click to bring
the window forward.

**Why review, not autobuild:** it adds a *second* always-visible surface; you'll
want to shape what it shows (artwork? scrubber? just controls?) and whether it's
toggleable in Settings. Low technical risk, medium design surface. Good
candidate for the next session — I can scaffold a minimal version in ~1 pass.

## 3. iCloud sync of settings/queue — needs an entitlement (your Apple account)

**Settings:** the lazy native answer is `NSUbiquitousKeyValueStore` (iCloud
key-value, 1 MB) — a near drop-in for the UserDefaults we already use. Small,
clean. **But** it requires the iCloud entitlement + container on your Developer
ID, added to the signing/notarization flow (`Scripts/build-app.sh`). That's the
part only you can set up (and it needs two Macs to test).

**Queue:** skip for now. It's large, changes constantly, and cross-device queue
sync is finicky (conflict resolution, "which Mac is playing"). Low value/effort
ratio v1. Revisit if settings sync lands well.

**Proposal:** when you've added the iCloud capability, I mirror the handful of
`SettingsManager` keys into `NSUbiquitousKeyValueStore`. ~20 lines.

## 4. Community translation platform — use a service, don't build one

Building a translate-and-auto-PR web app is a lot (GitHub token, PR creation,
UI). The lazy, correct answer is an existing OSS-tier service that already does
String Catalog + GitHub:
- **Crowdin** (free for OSS) or **Weblate** (free hosted for libre projects).
- Connect the repo, point it at `Localizable.xcstrings`, and it opens PRs when
  translators submit. Contributors get a web UI; you review PRs.

**What I already shipped to help:** `Scripts/check-localization.py` reports
per-language coverage and which `String(localized:)` keys are missing from the
catalog (currently 80). Run it in CI to stop new English-only strings from
shipping. **Your move:** pick Crowdin vs Weblate and create the project (needs
your account) — then I wire the config + a CI check.
