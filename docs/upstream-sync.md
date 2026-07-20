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

**Baseline:** everything up to upstream `50685c9` is already in `main` via the
wholesale merge `f180d2e` (2026-07-13). Only PRs merged upstream *after* that
point are tracked individually below.

## Pending (to sync)

None outstanding as of upstream `9fc8c34` (last sync). Re-check with the commands
above; cross-check any new `+` result by PR number against the tables below
before taking it.

## Already synced

Individually cherry-picked/adapted since the `f180d2e` baseline (newest first).

| PR | Upstream | Our commit | What it is |
|----|----------|-----------|-----------|
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
| `356ff92` — fix(player): harden playback reliability and queue ownership ([#374](https://github.com/sozercan/kaset/pull/374)) | Deep PlayerService rework: account session generations (`accountSessionGeneration`), queue-ownership/undo machinery, `SongLikeStatusManager.invalidateSession`, account-scoped playback metadata clearing. | Touches PlayerService wholesale; the fork's PlayerService has diverged and none of the reported failure modes are reproducible here. Skipping keeps our diff small; #388 was ported around it (its `invalidateSession(clearsActiveCache: false)` hunk was dropped — the method doesn't exist here). | Take it as a whole in a dedicated session (it will conflict heavily), then re-check every later player fix we adapted around it — starting with #388 (`13cf2c4`), whose dropped hunk becomes relevant again. |
| `7e1cbb4` — fix(library): reconcile liked music rating races ([#392](https://github.com/sozercan/kaset/pull/392)) | Rating-revision reconciliation built on #374's machinery. | Conflicts in `SongLikeStatusManager`/`PlayerService+Library`/`PlaylistDetailViewModel` because it assumes #374: instance-injected `songLikeStatusManager`, `invalidateSession(clearsActiveCache:publishesRollbackEvents:)`, `accountSessionGeneration`, `ratingRevision(for:accountID:)`, `setStatus` returning `Bool`. Unportable without #374. | Take with #374 in the same session. |
| `a527853` — fix(ai): restore discovery commands and macOS 27 compatibility ([#391](https://github.com/sozercan/kaset/pull/391)) | AI discovery-command restore + macOS 27 error handling. | Heavy conflict in `CommandExecutor`/`CommandBarViewModel`: changes the `musicIntent(MusicIntent)` enum case to carry `originalQuery`, cascading through the file, and reintroduces #374's queue-ownership (`QueueCommandOwnership.queueGeneration`, `requiresPlaybackClaim`). Not safely resolvable without test coverage (test target is broken here). | Revisit after #374; the macOS 27 `AIErrorHandler` part could be split out and taken alone if needed. |
| `0eadb78` — fix(player): de-flake Smart Shuffle tests by reading config per-instance ([#389](https://github.com/sozercan/kaset/pull/389)) | Test de-flake + per-instance config read in PlayerService. | Conflicts in the diverged `PlayerService`/`PlayerService+SmartShuffle`, and the payoff is test stability — but the fork's test target doesn't build, so there's no gain today. | Take when the test target is restored (likely alongside #374). |
| `c8e15f9` — feat: YouTube-style segmented seek bar for mixes ([#368](https://github.com/sozercan/kaset/pull/368)) | Segmented mix seek bar (UI feature). | Conflicts across 7 queue-machinery sources (`PlayerService+Queue`/`+QueueHistory`/`+WebQueueSync`/`+PlaybackRestoration`, `KasetApp`, `MiniPlayerWebView+Coordinator`, `PlayerBarProgressLane`) — the #374-divergence zone. A UI nicety, not worth a high-risk manual merge without tests. | Revisit after #374, or port the `PlayerBarProgressLane` UI alone if the segmented bar is wanted independently. |

Add a row **whenever a cherry-pick drops a hunk or an upstream commit is skipped
on purpose** — the cost of a stale entry is one line; the cost of a mystery gap
is an afternoon of archaeology.
