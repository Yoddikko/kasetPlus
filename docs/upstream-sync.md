# Upstream sync ledger

Tracks the fork's sync state against `sozercan/kaset`: what's **pending**, what's
**already taken**, and what we **deliberately skip** — so a future sync can tell a
skipped commit from a missed one, and doesn't re-take something already ported.

Check what's pending with:

```bash
git fetch upstream
git log --oneline --no-merges main..upstream/main   # commits we don't have as ancestors
git cherry main upstream/main                        # '+' = not applied even as a patch
```

Cross-check every `+` by **PR number** against the "Already synced" table below
before re-taking it: `git cherry` still shows `+` for adapted picks because the
patch-ids differ once the fork's code has diverged.

**Convention:** upstream fixes are **cherry-picked onto `main`**, adapted where
the fork diverged, keeping the original author and message (the `(#NNN)` suffix is
sometimes dropped, but the subject is preserved). Add a row to the relevant table
on every pick or skip.

**Baseline / ancestry:** everything up to upstream `50685c9` came in via the
wholesale merge `f180d2e` (2026-07-13). Since then, upstream PRs are
**cherry-picked** (adapted), so their original SHAs are not in our ancestry —
which is why GitHub showed the fork "N commits behind" even after syncing.
On 2026-07-21, after cherry-picking through upstream `c1dae03`, a
`git merge -s ours upstream/main` recorded that main is caught up **without
changing any code** (we already had the content): the fork now reads **0
behind**, and `git log main..upstream/main` starts empty from `c1dae03`.
Repeat that `-s ours` merge after each cherry-pick batch to keep the baseline
clean. (The fork stays permanently "ahead" — that's its own features, expected.)

## Pending (to sync)

None tractable outstanding as of upstream `c1dae03` (last sync). Re-check with the
commands above; cross-check any new `+` result by PR number against the tables
below before taking it.

## Already synced

Individually cherry-picked/adapted since the `f180d2e` baseline (newest first).

| PR | Upstream | Our commit | What it is |
|----|----------|-----------|-----------|
| [#383](https://github.com/sozercan/kaset/pull/383) | `e0bb015` | `7a7ca1e` | fix: scope favorites per account — the account-scoped-favorites rework (**+4398 lines**): `FavoritesManager` (+947), `AccountService` (+663), `AuthService` (+184), `YTMusicClient`/`YouTubeClient`, `LoginSheet`, a legacy-migration claim system, ADR 0030, plus a +740-line `FavoritesManagerLegacyMigrationClaimTests`. Nearly all auto-merged; one conflict in `MainWindow.swift` resolved to HEAD — kept the fork's onboarding/What's-New auto-present `.task` AND the login-check `.task` (idempotent; KasetApp's root task already drives startup login/account fetch). New test's import renamed `Kaset`→`KasetPlus`. Fork behaviours confirmed intact: guest mode, brand accounts (`brandId`/`onBehalfOfUser`), Community hub, sidebar pinned favorites. #383's favorites/account/auth suites all pass. |
| [#387](https://github.com/sozercan/kaset/pull/387) | `c1dae03` | `0ef8bbb` | fix(player): claim Now Playing slot so media keys control Kaset when paused — applied clean on top of #374's `NowPlayingManager`. New test file's import renamed `Kaset`→`KasetPlus`. |
| [#398](https://github.com/sozercan/kaset/pull/398) | `e44cbb1` | `38a5523` | feat(youtube): segment video chapter seek bar — applied clean on top of #368's `PlayerBarProgressLane`. New test file's import renamed. |
| [#368](https://github.com/sozercan/kaset/pull/368) | `c8e15f9` | `2b1fa21` | feat: YouTube-style segmented seek bar for mixes — new `NowPlayingTracklistProvider`, extended `MixTracklistParser`, rewritten `PlayerBarProgressLane`/`PlayerBar`. Two conflicts resolved (`KasetApp.swift`, `PlayerBarProgressLane.swift`): kept the fork's heatmap "most replayed" curve and `onHoverFractionChange` on-video overlay callback alongside the incoming segmented track + hovered-segment handling. Landed after #374. |
| [#389](https://github.com/sozercan/kaset/pull/389) | `0eadb78` | `80ff911` | fix(player): de-flake Smart Shuffle tests by reading config per-instance (applied clean once #374 restored the test target). |
| [#391](https://github.com/sozercan/kaset/pull/391) | `a527853` | `53cda79` | fix(ai): restore discovery commands and macOS 27 compatibility — applied clean (the `musicIntent` `originalQuery` cascade and queue-ownership symbols resolved thanks to #374). New AI test files renamed `@testable import Kaset` → `KasetPlus`. |
| [#392](https://github.com/sozercan/kaset/pull/392) | `7e1cbb4` | `a89fd9d` | fix(library): reconcile liked music rating races — one conflict in `PlayerService+Library.swift` resolved to the instance-injected `self.songLikeStatusManager.cacheGeneration` (#374's injected manager). Rating-revision reconciliation on #374's machinery. |
| [#374](https://github.com/sozercan/kaset/pull/374) | `356ff92` | `4ee7d62` | fix(player): harden playback reliability and queue ownership — the foundation port (account session generations, queue-ownership/undo, `SongLikeStatusManager.invalidateSession`, account-scoped playback metadata clearing). Unblocked #392/#391/#389/#368 above. Port plan/conflict map: `docs/upstream-374-port.md`. |
| [#379](https://github.com/sozercan/kaset/pull/379) | `9fc8c34` | `97c99cc` | fix: defer playback shortcuts while editing text (applied clean) |
| [#396](https://github.com/sozercan/kaset/pull/396) | `9a42bf6` | `9a8dba9` | fix(search): preserve semantic results and pagination — app source applied clean; conflicts only in the api-explorer tool, a test helper, and the ADR index (all resolved to incoming). ADR rows for `0026`/`0027` dropped: those ADRs belong to the skipped #374 and aren't in the fork. |
| [#388](https://github.com/sozercan/kaset/pull/388) | `fefd318` | `13cf2c4` | fix(player): keep now-playing like status in sync with the like cache — its `invalidateSession(clearsActiveCache:)` hunk was dropped (method absent here; see #374 skip) |
| [#386](https://github.com/sozercan/kaset/pull/386) | `c917dc6` | `3e17c4d` | fix(l10n): correct Italian subscribe terminology and other strings |
| [#385](https://github.com/sozercan/kaset/pull/385) | `25a4b86` | `a3362b1` | fix: deliver kaset:// deep links via AppDelegate |
| [#380](https://github.com/sozercan/kaset/pull/380) | `879a7fb` | `3b000d6` | fix: pop nested navigation on sidebar re-select |
| [#378](https://github.com/sozercan/kaset/pull/378) | `47a7d4f` | `1e3f231` | feat: expand UI localizations to 15 languages |
| [#370](https://github.com/sozercan/kaset/pull/370) | `c1eedff` | `51515c6` | feat: create playlists from the sidebar |

Anything not listed here and older than the baseline came in wholesale via `f180d2e`.

## Deliberately skipped

What we deliberately do **not** take, so a future sync doesn't mistake a skipped
commit for a missed one.

| Upstream | What it is | Why skipped | If we ever need it |
|----------|-----------|-------------|--------------------|

_#374 (`356ff92` → `4ee7d62`) and its four dependents #392/#391/#389/#368 all landed — see "Already synced" above._

Add a row **whenever a cherry-pick drops a hunk or an upstream commit is skipped
on purpose** — the cost of a stale entry is one line; the cost of a mystery gap
is an afternoon of archaeology.
