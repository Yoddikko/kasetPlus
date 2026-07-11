# Performance Audit — Energy, Heat & UI Fluidity

**Date:** 2026-07-10 · **Scope:** whole app, focused on the reported symptoms:
overheating / battery drain, and stutter around video playback (play/pause,
watch page). Static audit — no code was changed. Every finding below must be
**confirmed with measurement before fixing** (see §0), per the repo's
"measure before you fix" rule.

Baseline: commit `fbba637`, after the #355 energy-efficiency pass (which already
made the bridge scripts event-driven and the ambient timeline 8 Hz).

---

## 0. How to measure (do this first)

The app splits work across **three processes**: the native app, the music
WebView's WebContent process, and the YouTube watch WebView's WebContent
process. The first step of any fix is knowing *which process* is hot:

```bash
# Per-process CPU/energy while reproducing (video playing, then paused):
sudo powermetrics --samplers tasks --show-process-energy -i 5000 | grep -iE "kaset|WebKit.WebContent"

# GPU/compositing cost of the native side:
# Instruments → Core Animation FPS + Time Profiler on Kaset while a video plays.
# SwiftUI re-render churn: Instruments → SwiftUI template ("View Body" counts).
```

Expected split based on this audit: WebContent (watch page) dominates CPU;
the native app dominates GPU (ambient backdrop + Liquid Glass); SwiftUI
re-render churn at 1 Hz explains the "not fluid around pause" feel.

---

## 1. P0 — Video playback (the overheating scenario)

### 1.1 Ad-block fallback polls the DOM every 150 ms, forever
`Sources/Kaset/Services/AdBlockService.swift:228`

The "aggressive ad-skip fallback" runs `setInterval(..., 150)` for the lifetime
of every watch page. Each tick does `getElementById`, two `querySelector`s and a
`querySelectorAll` that includes `button[aria-label*="Skip"]` — an
attribute-substring scan over the whole document — **~6.7×/sec, even while the
video is paused and even when no ad has ever shown**. This is the single
cheapest big win in the WebContent process.

- [x] **DONE (2026-07-10):** Event-driven via a `MutationObserver` on
  `#movie_player`'s `class` attribute; a 250 ms skip loop runs only while
  `ad-showing` is present, and the selector scans are scoped to the player
  instead of the whole document.
- [x] **REWRITTEN (2026-07-10):** The whole primary ad-block path was replaced
  after research into uBlock Origin (`json-prune`) and th-ch/youtube-music's
  production "InPlayer" strategy. It now **prunes ad keys from the parsed
  object** by proxying `JSON.parse` + `Response.prototype.json` (+ an inline
  `ytInitialPlayerResponse` setter trap) instead of string-renaming keys and
  rebuilding `Response` objects. This fixed a **playback regression** (rebuilt
  responses dropped `response.url`, which the player checks → videos wouldn't
  start) and stopped touching `adBreakHeartbeatParams` (uBO preserves it;
  pruning breaks playback). Hooking prototype methods also survives YouTube
  re-capturing a pristine `fetch`. Only `adPlacements`/`playerAds`/`adSlots`
  are removed. Pruning logic covered by a node self-check.

### 1.2 The hidden watch-page DOM keeps running at full cost
`Sources/Kaset/Views/YouTube/YouTubeWatchWebView+Scripts.swift` (extraction +
observer scripts)

The extraction hides YouTube's chrome with `visibility: hidden`, but hidden
elements **still lay out and their JS still runs**: comments, related rail,
live-chat modules, Polymer observers — the entire watch SPA stays alive behind
the video. On top of that there are **two document-wide
`MutationObserver`s with `{ childList: true, subtree: true }`** (observer
script `installVideoObserver` at line ~241, extraction `installObserver` at
~486). YouTube mutates its DOM constantly, so each churn schedules attach
debounces and 1–6-frame RAF enforcement bursts.

- [x] **DONE (2026-07-10):** `#masthead-container`, `#secondary`, `#below`,
  `#comments`, `#related`, `#chat`, `ytd-live-chat-frame` are `display: none`
  in the extraction stylesheet, so they leave layout and their lazy-load
  IntersectionObservers never fire. (Note: a live-chat iframe's own JS is not
  stopped by `display:none` — revisit if live streams still run hot.)
- [x] **DONE (2026-07-10):** Both observers narrow from the document to
  `#movie_player` once it exists; `yt-navigate-finish` re-arms attach and
  re-runs the extraction after SPA navigations; the marked-chain observer
  additionally watches `childList` so a player reparent (theater/miniplayer,
  which mutates ABOVE `#movie_player`) still triggers re-marking.

### 1.3 AmbientVideoBackdrop `.live`: full-window blur re-rendered 8×/sec
`Sources/Kaset/Views/YouTube/AmbientVideoBackdrop.swift:128–250`

The `.live` aurora is a `TimelineView` at 8 Hz driving a ZStack of up to
**10 window-sized `RadialGradient`s (2 crossfade layers × 5 blobs)** through
`compositingGroup()` + `blur(radius: 46)` — a full-window offscreen render +
gaussian blur on every tick. Additionally `liveFraction` changes every second
(1 Hz progress) and retriggers a 0.7 s `.animation`, so the crossfade is
effectively always animating. This is the dominant *native GPU* cost while a
video plays, layered under Liquid Glass which then refracts it (another
offscreen pass).

- [ ] **TODO:** Render each swatch-set's aurora **once** into a cached image
  (offscreen `ImageRenderer` / pre-blurred bitmap per storyboard frame) and
  animate only cheap transforms (offset/opacity) between cached images. The
  drift illusion survives; the per-frame blur disappears. (Still open — do
  this only if the interim fix below doesn't measure well enough.)
- [x] **DONE (2026-07-10):** single aurora layer whose blob colors blend
  pairwise between the two storyboard cells around the playback position
  (no more 0.7 s crossfade animation re-triggered by every 1 Hz progress
  update), and the **full-window `blur(radius: 46)` is gone entirely** —
  softness now comes from multi-stop radial gradient falloff, which costs
  ~nothing per tick. The drift stays always-on by explicit user preference
  (a pause-suspend was tried and reverted). Occlusion/app-inactive gating
  (§4.1) is still open; the cached-image TODO above is likely moot now.

### 1.4 YouTubeWatchView re-evaluates its entire body at 1 Hz
`Sources/Kaset/Views/YouTube/YouTubeWatchView.swift`

The watch view's `body` reads `youtubePlayer.progress` (via
`ambientLiveFraction` at :57 and `isActiveChapter` at :697). With
`@Observable`, that makes the **whole page body** — metadata, chapter rail,
related column, comments — re-evaluate on every 1 Hz bridge update. Worse,
`commentsSection` (:761) recomputes `filteredComments` with
`localizedCaseInsensitiveContains` over **all loaded comments inline in the
body**, so a long comment list is re-filtered every second while the video
plays. This is a prime suspect for the "not fluid, especially around
play/pause" feel (pause fires extra forced updates: `pause`, `seeked`,
`waiting` events all send `STATE_UPDATE`).

- [x] **DONE (2026-07-10):** progress/duration reads extracted into
  `WatchAmbientBackground` and `WatchChaptersSection` child views; the parent
  body no longer reads them. Additionally `updatePlaybackState` now assigns
  observable properties only when the value actually changed (`@Observable`
  notifies on every write regardless of equality), so `isPlaying`/`duration`/
  `isShowingAd` readers — including the player bar — are no longer
  invalidated by every 1 Hz tick, and `lastNonAdContentProgress` is
  `@ObservationIgnored`.
- [x] **RESOLVED differently (2026-07-10):** the comment filter stays inline —
  with the parent body no longer re-evaluating at 1 Hz, it now runs only on
  real changes (typing, comment loads, play/pause transitions), which was the
  actual cost. Move it to the view model only if profiling still shows it.

---

## 2. P1 — WebView polling & scripts (music side)

### 2.1 Music observer scans every button on the page, up to 2×/sec
`Sources/Kaset/Views/SingletonPlayerWebView+ObserverScript.swift:368–483`

`sendUpdate` runs at 1 Hz (poll) plus mutation-driven sends (500 ms throttle).
Every invocation runs
`document.querySelectorAll('tp-yt-paper-button, button, [role="button"]')`
and iterates **all buttons on the YT Music page** just to detect the
Song/Video toggle (`hasVideo`). The YTM SPA has hundreds of buttons.

- [ ] **TODO:** Compute `hasVideo` only when the track changes
  (`trackChanged === true`), not on every update; cache it per `videoId`.
  Alternatively query a specific selector for the toggle renderer instead of
  scanning everything.

### 2.2 MiniPlayer web view: unthrottled observer + permanent 1 Hz interval
`Sources/Kaset/Views/MiniPlayerWebView.swift:106–124`

The MutationObserver fires `sendUpdate` on *every* mutation of the player-bar
subtree with `attributeOldValue`/`characterDataOldValue` (no throttle, unlike
the main observer), plus a `setInterval` at 1 Hz that never stops (even
paused). Only matters while the mini player is open, but it duplicates the
work the singleton observer already does.

- [ ] **TODO:** Reuse the main observer's throttle pattern (500 ms trailing
  throttle) and stop the interval while paused — or better, drive the mini
  player from the native `PlayerService` state instead of a second bridge.

### 2.3 SponsorBlock keeps two intervals alive with nothing to do
`Sources/Kaset/Views/YouTube/YouTubeWatchWebView+Scripts.swift:608–633`

A 1.5 s SPA-navigation check and a 250 ms skip monitor run for the page's
lifetime, including when paused or when the video has no segments.

- [ ] **TODO:** Drive the skip check from the video's `timeupdate` event
  (fires ~4 Hz only while playing — same granularity as the 250 ms poll,
  zero cost when paused). Replace the SPA poll with the `yt-navigate-finish`
  page event.

---

## 3. P1 — Native animation costs

### 3.1 `TimelineView(.animation)` = display-refresh-rate invalidation
`Sources/Kaset/Views/SharedViews/SkeletonView.swift:47`,
`Sources/Kaset/Views/SharedViews/AnimationModifiers.swift:146` (PulseModifier)

`.animation` (no minimum interval) invalidates at up to 120 Hz **per
instance**. A loading screen shows dozens of `SkeletonView`s (e.g. the watch
view's related rail renders 5, Home many more), so "loading" screens burn CPU
frames precisely when the app also does network + decode work.

- [ ] **TODO:** Use `TimelineView(.animation(minimumInterval: 1/30))` for the
  shimmer (30 Hz is indistinguishable for a soft gradient sweep), or share
  one phase across all skeletons via a single injected timeline value.
  Same for `PulseModifier`.

### 3.2 Always-on `repeatForever` animations
`Sources/Kaset/Views/SharedViews/EqualizerView.swift` (3 bars ×
`repeatForever`), `Sources/Kaset/Views/PlayerBarMarqueeText.swift` (continuous
linear scroll while a long title is shown),
`Sources/Kaset/Views/PlayerBarSliderLoadingShimmer.swift`.

Each visible instance keeps a Core Animation transaction alive at frame rate.
The marquee in particular scrolls forever in the player bar — including when
the window is occluded or the app is in the background.

- [ ] **TODO:** Gate these on window/app activity (see §4.1) and on
  Low Power Mode (the ambient backdrop already does this — reuse its
  pattern). The equalizer indicator could drop to a `TimelineView(.periodic)`
  at ~10 Hz shared across bars.

### 3.3 Player bars re-render at 1 Hz with heavy glass bodies
`Sources/Kaset/Views/YouTube/YouTubePlayerBar.swift`,
`Sources/Kaset/Views/PlayerBar.swift`

Both bars read `progress` in their body, so the full capsule (GeometryReader,
glass container, ~12 buttons, menus) re-evaluates every second during
playback. Mostly fine, but it compounds with 1.4 — on the watch page, one
bridge update currently re-evaluates the page body *and* the bar.

- [ ] **TODO:** After fixing 1.4, check View Body counts in Instruments; if
  the bar is still hot, extract the progress lane (`youtubeProgressSection` /
  `progressSection`) into a child view so only the lane re-renders per tick.

---

## 4. P2 — Cross-cutting hygiene

### 4.1 Nothing pauses when the app is hidden
No component (ambient backdrop, marquee, equalizer, skeletons, JS intervals)
observes window occlusion or app-active state. Music playing with the window
minimized still animates the marquee, re-renders bars at 1 Hz, and runs all
watch-page intervals.

- [ ] **TODO:** Introduce one shared observable, e.g.
  `EnvironmentValues.isRenderingActive`, fed by
  `NSWindow.didChangeOcclusionStateNotification` +
  `NSApplication.didBecome/didResignActiveNotification`, and gate every
  cosmetic animation on it (ambient backdrop, marquee, equalizer, shimmer).
  This is the single highest-leverage battery fix for the
  "app open in background" case.

### 4.2 Low Power Mode only reaches the ambient backdrop
`AmbientVideoBackdrop` downgrades under LPM; nothing else does.

- [ ] **TODO:** Reuse the same `isLowPowerModeEnabled` gate for skeleton
  shimmer, marquee, and equalizer (fall back to static rendering).

### 4.3 Micro (only if instruments show them)
- `YouTubePlayerService.updatePlaybackState` spawns `Task {}`s every second
  (storyboard refresh, RYD, DeArrow) — all internally deduped, but it's
  allocation churn on the 1 Hz path
  (`Sources/Kaset/Services/Player/YouTubePlayerService.swift:940–979`).
- `PlayerBarMarqueeText.appKitTextWidth` measures the string with
  `NSString.size(withAttributes:)` on every body evaluation
  (`PlayerBarMarqueeText.swift:113`) — cache per text.
- Hidden 1×1 music WebView renders the full YTM SPA; its paint cost is tiny
  (1×1) but page JS/animations still run. If powermetrics shows the *music*
  WebContent hot while only audio plays, consider injecting a
  `visibility: hidden` page style in audio-only mode (audio keeps playing).

---

## Suggested order of attack

| # | Item | Process | Expected win | Effort |
|---|------|---------|--------------|--------|
| 1 | ~~1.1 ad-block 150 ms poll~~ ✅ done | WebContent (video) | High — constant CPU | Small |
| 2 | ~~1.4 watch-view 1 Hz body re-render~~ ✅ done | App CPU | High — fixes "pause stutter" | Small–medium |
| 3 | ~~1.3 ambient blur per-tick render~~ ✅ interim done | App GPU | High — heat while video plays | Medium |
| 4 | ~~1.2 hidden DOM `display:none` + observer scoping~~ ✅ done | WebContent (video) | Medium–high | Medium |
| 5 | 4.1 occlusion/active gating | Both | High for background use | Medium |
| 6 | 2.1 music observer button scan | WebContent (music) | Medium | Small |
| 7 | 3.1 skeleton/pulse 120 Hz → 30 Hz | App GPU/CPU | Medium during loads | Small |
| 8 | 2.3 SponsorBlock intervals → events | WebContent (video) | Small–medium | Small |
| 9 | 2.2 mini-player observer throttle | WebContent (music) | Small | Small |
| 10 | 3.2/4.2 always-on animations + LPM | App GPU | Small each, additive | Small |

After each fix: re-run the §0 `powermetrics` comparison (video playing 2 min /
paused 2 min) and keep the numbers in the PR description.
