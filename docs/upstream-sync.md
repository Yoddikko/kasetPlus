# Upstream sync ledger

What we deliberately do **not** take from upstream (`sozercan/kaset`), so a
future sync doesn't mistake a skipped commit for a missed one. Check what's
pending with:

```bash
git fetch upstream
git log --oneline main..upstream/main   # commits we don't have as ancestors
git cherry main upstream/main           # '+' = not applied even as a patch
```

Convention: upstream fixes are **cherry-picked onto `main`**, adapted where the
fork's code diverged, keeping the original author and message (e.g. `a3362b1`
for #385, `3b000d6` for #380, `13cf2c4` for #388). `git cherry` will still show
`+` for adapted picks because the patch-ids differ — cross-check by PR number
in the commit title before re-taking anything.

## Deliberately skipped

| Upstream | What it is | Why skipped | If we ever need it |
|----------|-----------|-------------|--------------------|
| `356ff92` — fix(player): harden playback reliability and queue ownership ([#374](https://github.com/sozercan/kaset/pull/374)) | Deep PlayerService rework: account session generations (`accountSessionGeneration`), queue-ownership/undo machinery, `SongLikeStatusManager.invalidateSession`, account-scoped playback metadata clearing. | Touches PlayerService wholesale; the fork's PlayerService has diverged and none of the reported failure modes are reproducible here. Skipping keeps our diff small; #388 was ported around it (its `invalidateSession(clearsActiveCache: false)` hunk was dropped — the method doesn't exist here). | Take it as a whole in a dedicated session (it will conflict heavily), then re-check every later player fix we adapted around it — starting with #388 (`13cf2c4`), whose dropped hunk becomes relevant again. |

Add a row **whenever a cherry-pick drops a hunk or an upstream commit is
skipped on purpose** — the cost of a stale entry is one line; the cost of a
mystery gap is an afternoon of archaeology.
