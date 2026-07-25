# KasetPlus — Mix / Playlist / Chip-bar work — HANDOFF

Living plan for the in-progress YouTube Mix + Playlist + home Chip-bar work.
Another AI (or a future session) can continue from here. Delete when done.

## Repo / workflow facts
- Repo: `Yoddikko/kasetPlus` at `~/Documents/GitHub/kasetPlus`, branch `main`.
  Owner is in the branch-protection bypass list → direct commits/pushes to
  `main` work (unsigned warns but passes).
- Swift 6 / SwiftUI / macOS 26 SwiftPM app. Target `KasetPlus`, sources in
  `Sources/Kaset`. `@Observable @MainActor` singletons. `.compatGlass` styling.
- Build: `swift build`. Tests: `swift test --skip KasetUITests`. App bundle:
  `./Scripts/build-app.sh` → `.build/app/KasetPlus.app`.
  Relaunch cleanly (else `open` re-focuses the OLD running instance):
  `osascript -e 'quit app "KasetPlus"'; sleep 1; pkill -x KasetPlus; sleep 1; open .build/app/KasetPlus.app`
- `swiftlint`/`swiftformat` are NOT installed here; follow the file's existing
  `self.`-in-static convention (`.swiftformat` uses `--self insert`).
- Pre-existing test failures unrelated to this work: `AppLocalizationTests`
  (~xcstrings not compiled in `swift test`), `ListenBrainz` (network), one
  `SettingsManager` localization test, one `YouTubePlayerService` storyboard
  test. Ignore these.
- API probing: `swift run api-explorer --youtube ...`. Auth cookies ARE present
  now (signed in). Useful commands:
  - `--youtube -v action search '{"query":"..."}'` (raw JSON to stdout, prefixed
    by a summary — parse by scanning for the first `{` that decodes to a dict
    with both `contents` and `responseContext`).
  - `--youtube -v action next '{"videoId":"...","playlistId":"..."}'`.
  - `--youtube -v browse FEwhat_to_watch`.
  - GOTCHA: `browse FEwhat_to_watch` via api-explorer returns a home WITHOUT the
    filter chip bar (different client config than the app). So the home "Mix"
    topic-chip feed CANNOT be reproduced from api-explorer — see task (1).

## Done (already on main)
- `fc618b0` Add YouTube Mix support (search, home, watch box) + interleaved search.
- `2041519` Refine Mix box and stacked poster.
- `f78fb2e` Open YouTube playlists as a watch queue (right-side panel).

### Key mechanisms in place
- **Mix detection**: `YouTubeItemParser.mixVideo(fromLockup:)` — a Mix is a
  `lockupViewModel` with `contentType == LOCKUP_CONTENT_TYPE_PLAYLIST` and
  `contentId` prefixed `RD`, with a seed `onTap…watchEndpoint.videoId`. Produces
  a `YouTubeVideo` with `mixPlaylistId` set. Dispatched from
  `video(fromAnyItem)` (so search + home feed both catch mixes). Plain
  `videoRenderer`s are NOT flagged (every music video carries a "start radio" RD).
- **YouTubeVideo.mixPlaylistId** (now `var`) drives the "▶ Mix" badge +
  stacked-poster in `VideoThumbnailView`. Helper `YouTubeVideo.inMix(_:)` returns
  a copy carrying a playlist/mix context WITHOUT changing display — used to
  navigate/queue while keeping tracks visually plain.
- **Search interleaving**: `YouTubeSearchResponse.items: [YouTubeSearchItem]`
  (enum video/channel/playlist) preserves YouTube's original order; the search
  view renders `items` flat (no fixed sections). Mix seeded from a listed video
  stays distinct via id `"v:<videoId>:<mixPlaylistId>"`.
- **Watch up-next panel** (the right-side box) — `WatchNextParser` parses
  `contents.twoColumnWatchNextResults.playlist.playlist` into
  `WatchNextData.mixVideos` + `mixTitle` (titleText) + `mixDescription`
  (longBylineText) + `mixPlaylistId`, kept SEPARATE from `related`
  (`secondaryResults`). `YouTubeWatchView.mixBox` renders it: fixed height
  (~340pt) internally-scrolling, current track highlighted
  (`videoId == self.video.videoId`), tracks are plain (no "mix in mix"); the
  mix/playlist context is injected only at navigation/playback via `inMix`.
  `upNextQueue` feeds the transport `mixVideos.map{ $0.inMix(mixPlaylistId) }`.
  The SAME box works for ANY playlist (verified `PL…` returns the same panel).
- **Playlists open as a queue**: `YouTubePlaylist.watchTarget` builds a
  first-video `YouTubeVideo` with `mixPlaylistId = playlistId`; the 3 playlist
  nav sites (`YouTubePlaylistsView`, `YouTubeChannelView`, `YouTubeSearchView`)
  navigate to `.watch(watchTarget)` (fallback `.playlist(...)` when no first
  video). YouTube Music untouched.
- **Region**: `SettingsManager.ContentLanguage.apiRegionCode` (it→IT, de→DE, …);
  `YouTubeClient` sends it as `gl` (was hardcoded "US").

## TODO

### (1) Tag YouTube-Music mixes in the home "Mix" shelf as mixes
Problem: the home "Mix" topic row mixes video-mixes (RD playlist lockups → get
the "▶ Mix" badge) with YouTube-Music mixes (cover art like "2025",
"Cantautori", "Bachata Mix"). The latter show on youtube.com with a "▶ Mix"
badge but in-app render as plain cards (no badge). User wants them tagged too.

Blocker: can't see their renderer shape from api-explorer (chip-less home).

Plan:
1. CAPTURE the real data from the running app. The Mix rail is built by
   `YouTubeClient.getHomeTopicFeed(continuation:)` → `YouTubeFeedParser.parseContinuation`.
   Add a throwaway diagnostic there: when the response contains a music-mix-ish
   lockup, write the raw JSON to `NSTemporaryDirectory()` and `synchronize()`.
   Sandbox tmp read path:
   `~/Library/Containers/com.sertacozercan.Kaset/Data/tmp/`. (See CLAUDE.md
   "Debugging & Measurement" — os_log/`/tmp` don't work in the sandbox.)
   Build, ask user to open Home so the Mix rail loads, then read the dump.
2. Inspect: what renderer are the music mixes? Likely `lockupViewModel` with
   `contentType == LOCKUP_CONTENT_TYPE_PLAYLIST` and `contentId` like
   `RDCLAK5uy_…` / `RDEM…` / `RDAT…` (all start `RD`), but `mixVideo(fromLockup:)`
   currently REQUIRES a seed `onTap…watchEndpoint.videoId` — the music-mix lockup
   may not expose one (uses `watchPlaylistEndpoint`, or the videoId sits
   elsewhere). Confirm the exact `onTap` shape + where a playable seed videoId
   (or first track) lives.
3. Fix `mixVideo(fromLockup:)` to also handle that shape (e.g. deep-search for
   the first `watchEndpoint.videoId`, or read the collectionThumbnail's primary
   video id). Keep the guard that plain video lockups with a "start radio" RD
   are NOT mixes. Add a parser test with the captured fixture.
4. Strip the diagnostic before commit.

### (2) Home chip-bar (option A) — CHOSEN behaviour
YouTube-style filter chips at the top of Home: `Tutti · Musica · Mix · Podcast …`.
`Tutti` = current Home (personalized grid + topic rails). Tapping a chip loads
THAT chip's feed as a single grid (replacing rails/grid); tapping `Tutti`
returns. Does NOT remove the existing personalized Home.

Infrastructure already exists:
- `YouTubeClient.getHomeChips() -> [YouTubeHomeChip]` (title + continuation
  token; chips come localized via `hl`, region via `gl`).
- `YouTubeClient.getHomeTopicFeed(continuation:) -> YouTubeFeed` (browses a
  chip's continuation → a topic-filtered grid, with its own trailing
  continuation for pagination).
- Model `YouTubeHomeChip { title, continuation }`.

Files / steps:
- `YouTubeHomeViewModel` (`Sources/Kaset/ViewModels/YouTube/`): currently
  consumes chips into `pendingTopicChips` to build topic RAILS. Expose the full
  chip list: add `private(set) var chips: [YouTubeHomeChip] = []` populated at
  load (from the same `bundle.chips`). Add selected-chip state + a chip feed:
  `var selectedChip: YouTubeHomeChip?`, `private(set) var chipVideos: [YouTubeVideo] = []`,
  `chipContinuation`, `chipLoadingState`. Methods `selectChip(_:)` (nil = All →
  clear; else `getHomeTopicFeed(chip.continuation)` → publish `chipVideos`),
  `loadMoreChipVideos()`.
- `YouTubeHomeView` (`Sources/Kaset/Views/YouTube/`): add a horizontal chip bar
  at the top (an "All"/"Tutti" chip + `viewModel.chips`), styled like the search
  filter chips (`.compatGlass(interactive:true, tint: selected ? accent : nil,
  in: Capsule())`). When `selectedChip == nil` show the current
  `homeContent`/rails/grid; else show a `VideoCard` grid of `chipVideos` (reuse
  the existing grid `LazyVGrid`, with the load-more `.task`). Keep the bar
  pinned above the scrolling content.
- Localize the "All" label (`String(localized: "All")`); chip titles come from
  YouTube already localized.
- Verify the chips actually arrive (the app gets them even though api-explorer
  doesn't). If `getHomeChips` returns empty in some states, hide the bar.

### Nice-to-haves (from user screenshots, not yet done)
- Queue box: show position "N/total" and loop/shuffle controls (YouTube shows
  "Privato · Alessio · 1/15" + loop/shuffle for a playlist; mixes show the
  byline). `playlist.playlist` panel has `currentIndex` + `contents` count +
  `shortBylineText`; parse into `WatchNextData` and render in `mixBox` header.
- The queue box currently reuses "mix*" field names for generic playlists —
  functional but consider renaming to `queue*` for clarity (optional churn).

## User preferences / working rhythm
- Build → user tests with a screenshot → says "committa"/"pusha" → then commit.
  Prefers one coherent feature per cycle. Speaks Italian. Values fidelity to
  youtube.com behaviour ("dynamic from YouTube, less app logic").
- Always relaunch the freshly built app for the user (quit old instance first).
