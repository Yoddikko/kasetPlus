# Test Suite Repair & Quarantine Log

Branch: `feature/upstream-374-and-dependents` (KasetPlus fork of sozercan/kaset).

Goal of this pass: make the unit test target COMPILE and RUN
(`swift test --skip KasetUITests`). Individual test pass/fail is out of scope —
compile failure is not acceptable, runtime failures are.

## Outcome

- `swift build --build-tests`: compiles cleanly (0 errors).
- `swift test --skip KasetUITests`: runs — 1983 tests in 163 suites, 90 runtime
  failures (pre-existing behavioral/localization drift, unrelated to compilation).
- `swift build` (the app): still green.
- **Quarantined files: none.** Every broken test file was fixed in place.

## Root cause (the big cascade)

The ~36k reported compile errors were almost entirely a single cascade, not 50
independently-rotted files:

1. **Module rename not propagated to tests.** The fork's rebranding commit
   (`0fd9042`) renamed the app target `Kaset` -> `KasetPlus` in `Package.swift`
   and updated the test target's dependency to `["KasetPlus"]`, but left all
   151 test files doing `@testable import Kaset`. SwiftPM emitted a single
   `no such module 'Kaset'` for the test module's emit-module phase, which the
   compiler then reported once per compilation unit — producing tens of
   thousands of phantom "cannot find type / has no member" cascades against a
   module that never loaded.

   `moduleAliases` is only valid on external `.product(...)` dependencies, not
   on intra-package `.target(...)` dependencies, so aliasing in `Package.swift`
   is not an option. The fix was the mechanical, tests-only rename below.

2. A stale `.build` `Kaset.swiftmodule` initially masked the real error; a clean
   rebuild plus the import rename exposed the true (small) broken set.

## What was fixed (tests only — Sources untouched)

### Bulk rename (151 files)
- `@testable import Kaset` -> `@testable import KasetPlus` across all
  `Tests/KasetTests/**` files. Purely a module-name correction to match the
  renamed app target. No behavioral change.

### Helpers
- `Tests/KasetTests/Helpers/MockYTMusicClient.swift` — no change needed; already
  matched the current `YTMusicClientProtocol` once the module resolved.
- `Tests/KasetTests/Helpers/MockYouTubeClient.swift` — no change needed.
- `Tests/KasetTests/Helpers/MockScrobblingSettings.swift` — no change needed
  (cascade-only).
- `Tests/KasetTests/SwiftTestingHelpers/TestStringConvertible.swift` — no change
  needed (cascade-only).

### Individual test files (3)
- `Tests/KasetTests/YouTubePlayerServiceTests.swift`
  - Added `skipAd(resumeAt:)` to the private `MockYouTubeWatchPlaybackController`
    (method added to `YouTubeWatchPlaybackControlling` in the fork).
  - Rewrote the obsolete `storyboardRefreshTaskStartIsGuarded` test: the fork
    replaced the synchronous, bool-returning `startStoryboardSpecRefreshIfNeeded()`
    with the async, internally-guarded `refreshStoryboardSpec()`. The test now
    exercises the current async dedup behavior.
- `Tests/KasetTests/YouTubeSingleFlightViewModelTests.swift`
  - Added `getLiveChat(continuation:)` and `sendLiveChatMessage(text:params:)` to
    the private `SingleFlightYouTubeClient` (methods added to
    `YouTubeClientProtocol` in the fork).
- `Tests/KasetTests/StoryboardSheetTests.swift`
  - Removed two obsolete tests that referenced deleted static helpers
    `SettingsManager.defaultAmbientBackdropStyle` and
    `SettingsManager.resolveAmbientStyle(enabled:preferredStyle:)`. The fork
    replaced these with the instance-level `SettingsManager.resolvedAmbientStyle`
    computed property (and changed the default style). `SettingsManager` is a
    singleton with a private init, so the removed static logic can no longer be
    exercised via a constructible instance; the two tests were dropped with an
    explanatory comment. All other tests in the file were left intact.

## Quarantined files

None. The `MixTracklist*`, `ScrobblingCoordinatorMix*`,
`ProvisionalMixPlaybackHistoryTests`, and legacy search suites that the plan
flagged as candidates for quarantine turned out to be cascade-only: once the
module name was corrected they compiled without changes, so nothing was moved to
`Tests/KasetTests/_quarantined` and no `exclude:` entry was added to
`Package.swift`.

## How to restore quarantined files (for future passes)

No files are currently quarantined. If a future pass quarantines a file:

1. `git mv Tests/KasetTests/_quarantined/<File>.swift Tests/KasetTests/<File>.swift`
2. Remove `"_quarantined"` from the `exclude:` array of the `KasetTests`
   testTarget in `Package.swift` (only if the directory is now empty).
3. Fix the file to match the current `Sources/` API, then
   `swift build --build-tests` to confirm.

Never quarantine the four shared helpers
(`Helpers/MockYTMusicClient.swift`, `Helpers/MockYouTubeClient.swift`,
`Helpers/MockScrobblingSettings.swift`, `SwiftTestingHelpers/TestStringConvertible.swift`)
or the `Fixtures` resources dir — they are shared by the whole suite.
