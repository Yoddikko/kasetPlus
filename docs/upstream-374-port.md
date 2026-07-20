# Porting upstream #374 (and its dependents) — handoff notes

**Audience:** a future session that picks up the upstream sync for the PRs
blocked on #374. Read this *before* touching the player. It records what was
investigated on branch `feature/upstream-374-and-dependents`, why #374 was not
force-merged, and the concrete path to finish it.

See also `docs/upstream-sync.md` (the sync ledger: what's taken/pending/skipped).

## The goal and the dependency chain

Four pending upstream PRs all build on **#374** (`356ff92` — "fix(player):
harden playback reliability and queue ownership"), which the fork skipped:

```
#374  (queue-ownership + generation-scoped web-playback bridge)   ← foundation
  ├── #392  fix(library): liked music rating races
  ├── #391  fix(ai): restore discovery commands + macOS 27
  ├── #389  fix(player): de-flake Smart Shuffle tests
  └── #368  feat: YouTube-style segmented seek bar for mixes
```

Taking #374 first unblocks all four (they then apply/adapt with little
conflict). Cherry-picking them without #374 fails — they reference symbols #374
introduces (`invalidateSession(clearsActiveCache:publishesRollbackEvents:)`,
`accountSessionGeneration`, `ratingRevision(for:accountID:)`,
`QueueCommandOwnership.queueGeneration`, `requiresPlaybackClaim`, `SongLikeStatusManager.setStatus` returning `Bool`, …).

## Why #374 is not a cherry-pick

#374 is **21,105 insertions / 2,078 deletions across 102 files** — a wholesale
rewrite of the playback/queue/web-bridge core. It introduces a new architecture:
per-document *generation-scoped* bridge events, tracked navigations, queue
ownership, and playback intents. New files it adds (all must land):

- `Services/Player/WebPlaybackDocumentGeneration.swift` (+527)
- `Services/Player/MusicPlaybackIntent.swift` (+516)
- `Services/Player/PlayerService+QueueHistory.swift` (+268)
- `Services/Player/PlayerService+PlaybackBoundaries.swift` (+145)
- `Services/Player/MusicPlaybackOccurrence.swift` (+50)
- `Views/MiniPlayerWebView+Coordinator.swift` (+689)
- `Views/YouTube/YouTubeWatchWebView+Coordinator.swift` (+292)
- `Views/YouTube/YouTubeWatchWebView+RecoverySeek.swift` (+311)
- `Views/YouTube/YouTubeWatchWebView+DocumentGeneration.swift` (+105)
- ADRs `0026-generation-scoped-web-playback-bridge.md`, `0027-native-music-playback-intents-and-queue-entry-identity.md`
- ~15 new test files (thousands of lines)

**Good news:** git auto-merges ~95 of the 102 files. The fork's divergence and
#374's rewrite mostly touch different regions of the *music* core, so those
merge textually. **But auto-merge on a 21k-line rewrite is not proof of
correctness** — semantic breakage won't show until runtime, and the fork's test
target does not build (so there's no automated safety net; see below).

## The real blocker: a two-architecture clash in YouTube video playback

The cherry-pick conflicts in **6 source files** (measured on this branch):

| File | Conflict blocks | Nature |
|------|-----------------|--------|
| `Views/YouTube/YouTubeWatchWebView.swift` | 7 | **Architecture clash** (see below) |
| `Services/Player/YouTubePlayerService.swift` | 7 | Fork's live/controls vs #374 bridge |
| `Views/YouTube/YouTubeWatchWebView+Scripts.swift` | 3 | Bridge observer script divergence |
| `Services/Player/PlayerService+Library.swift` | 1 | Small; like-status wiring |
| `Sources/APIExplorer/main.swift` | 4 | Dev tool; fork's YouTube-mode additions |
| `docs/adr/README.md` | 1 | Additive (ADR index) |
| + 2 test files | — | `MusicPlaybackBridgeGenerationTests`, `PlayerServiceQueueHistoryTests` |

The conflicts concentrate in exactly the files the fork rewrote for its own
features (**live streams, controls-on-video, YouTube source, ad-block recovery**)
— and #374 rewrites those same files for its bridge. Concretely, in
`YouTubeWatchWebView.swift`:

- **Ours (fork):** `private(set) var documentGeneration = 0` (a plain `Int`
  counter) plus a ~211-line block of live-stream / controls / recovery-seek
  logic the fork built around it.
- **Theirs (#374):** `documentGeneration = WebPlaybackDocumentGeneration()` (a
  struct) plus a family of companion trackers (`documentNavigations`,
  `pendingSeeksByGeneration`, `continuationGenerationsAwaitingStart`,
  `directSeekGenerations`, …), with the recovery logic *relocated* to the new
  `+RecoverySeek` / `+Coordinator` files.

These are two different implementations of the same concept. Resolving it means
**adopting #374's architecture and re-implementing the fork's video features
(live, controls-on-video, ad-block recovery) on top of it** — then verifying
nothing regressed. That is a dedicated integration effort, not a merge-marker
cleanup, and it must be validated by a test suite.

## Prerequisite: restore the test target — ✅ DONE (`c78aa6a`)

**Resolved on this branch.** The test target's ~36k errors were a single
cascade, not stale files: the rebranding renamed the app target `Kaset` →
`KasetPlus` but left every test on `@testable import Kaset`, so the test module
never loaded. Fixed by the import rename across 151 files (+ 3 small drift
fixes); `swift test --skip KasetUITests` now compiles and runs (1983 tests, 90
pre-existing runtime failures). See `docs/test-suite-recovery.md`.

This matters because #374 is a *reliability/race* rework whose real validation
is its own test suite (~15 new player test files it ships). With the target
restored, those tests can now gate the port.

## Recommended execution plan (dedicated session)

1. **Restore the test target** so `swift test --skip KasetUITests` builds.
2. Branch from `main`; `git cherry-pick 356ff92`.
3. Resolve the 6 conflicts. Order: tooling/docs first (api-explorer, ADR
   README, `PlayerService+Library`), then the hard three:
   - Take #374's `WebPlaybackDocumentGeneration` architecture as the base.
   - Re-apply the fork's live-stream / controls-on-video / ad-block-recovery
     behaviour on top, using #374's new `+RecoverySeek`/`+Coordinator` seams
     instead of the old `Int` generation.
   - Cross-check `YouTubeWatchWebView+Scripts.swift` observer script against
     #374's `window.__kasetDocGeneration` protocol.
4. `swift build`, then run the full player test suite; iterate.
5. Manually verify: music playback + queue, YouTube video, **live streams**,
   **controls-on-video**, mini-player, ad-block. These are the fork features most
   at risk.
6. Then take the dependents in order — they should apply with minor conflicts:
   `#392` → `#389` → `#391` → `#368`. Update `docs/upstream-sync.md` as each lands.
7. Restore ADR rows `0026`/`0027` in `docs/adr/README.md` (dropped when #396 was
   taken, because those ADR files arrive with #374).

## Alternative: ship only the #368 seek bar, without #374

If the segmented mix seek bar is wanted for UX *now* and #374 is not on the
table, extract #368's self-contained pieces and adapt them to the fork's
(pre-#374) queue:

- New/extended data: `Services/Player/NowPlayingTracklistProvider.swift` (+157,
  new), `Services/Scrobbling/MixTracklistParser.swift` (+168 — the fork already
  has this parser for scrobbling).
- UI: `Views/PlayerBarProgressLane.swift` (+315), `Views/PlayerBar.swift` (+74).
- Localization strings (harmless additions).
- **Adapt, don't take:** #368's hooks in `PlayerService+Queue/+WebQueueSync/
  +PlaybackRestoration` assume #374's queue events. Re-wire the provider to the
  fork's existing queue/position signals instead.

Caveat: this delivers the UI but not #374's race-hardening; validate by running
the app (music mix playback + seeking + track changes) and revert if playback
regresses. Track it as its own row in the sync ledger.

## Status snapshot (2026-07-20)

| PR | State |
|----|-------|
| #396, #379 | ✅ synced to `main` |
| test target | ✅ restored on this branch (`c78aa6a`) — the #374 prerequisite is cleared |
| #374 | ◻︎ ready to attempt: 6 source conflicts (see map), ~17 two-architecture blocks in `YouTubePlayerService`/`YouTubeWatchWebView`. Resolve by adopting #374's plumbing (`WebPlaybackDocumentGeneration`, `effectiveIsPlaying`) while **preserving the fork's live-stream / controls-on-video / ad-skippable logic** (e.g. `YouTubePlayerService` block @L1518 merges the fork's ad/live/spinner state application with #374's `effectiveIsPlaying`). Gate on the restored test suite + #374's own player tests, then smoke-test YouTube video + live + controls-on-video. |
| #392, #391, #389, #368 | ⛔ blocked on #374 |
| #368 (UI only) | ◻︎ optional standalone extraction (see above) |

## Reproduce the conflict map

```bash
git fetch upstream
git checkout -b try-374 main
git cherry-pick 356ff92
git diff --name-only --diff-filter=U          # the 6 source + 2 test conflicts
git cherry-pick --abort                        # don't leave it half-merged
```
