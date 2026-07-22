---
name: check-telemetry
description: "Check recent KasetPlus breakage telemetry (parse/HTTP failures the app reports when YouTube changes something) from the Cloudflare Worker. Use when asked to check telemetry, diagnostics, or whether something broke in the wild."
---

# Check Telemetry

KasetPlus sends anonymous breakage pings to its Cloudflare Worker when the shared
YouTube Music request path hits an unexpected failure — a response that no longer
parses (`ytm.parse_fail`) or an unexpected HTTP status (`ytm.http_error`). This
skill pulls the recent events and summarizes them so you can spot a YouTube-side
break within minutes instead of via user reports.

Background: `Sources/Kaset/Services/Telemetry.swift` (app side) and the
`/telemetry` + `/telemetry/recent` routes in `worker/src/index.js`. Events are
anonymous (event name, endpoint, app/OS version, throwaway install id), stored in
KV with a 7-day TTL.

## How to run

The endpoint is **maintainer-only**: it requires the `KASET_TELEMETRY_TOKEN`
(kept in your shell env / a local dotfile — **never committed**). If the variable
isn't set, ask the user to `export KASET_TELEMETRY_TOKEN=…` first (the value is
the Worker's `TELEMETRY_TOKEN` secret).

```bash
curl -s -H "X-Telemetry-Token: $KASET_TELEMETRY_TOKEN" \
  "https://kaset-lastfm.alessioiodiceuni.workers.dev/telemetry/recent"
```

A `401` means the token is missing or wrong.

Response shape:

```json
{ "count": 3, "events": [
  { "ts": "2026-07-22T07:01:08.992Z", "event": "ytm.parse_fail",
    "detail": { "endpoint": "search" }, "app": "0.12.0 (36)",
    "os": "macOS 26.0", "id": "tester-01" }
] }
```

## What to report

Summarize, don't dump. Present:

1. **Headline** — total events in the window, and how many are `ytm.parse_fail`
   (the "YouTube changed a response shape" signal — call these out first; they
   usually mean a parser needs fixing).
2. **By event type** — count of `ytm.parse_fail` vs `ytm.http_error` (include the
   HTTP `code` from `detail` when present).
3. **By endpoint** — which `detail.endpoint`s are failing, with counts. A single
   endpoint dominating points at one broken call; many endpoints at once points
   at auth/session or a broad YouTube change.
4. **Reach** — distinct install ids (`id`) affected, and which app versions
   (`app`). One id = probably just testing; many = a real in-the-wild break.
5. **Freshness** — timestamp of the newest and oldest event shown.

If `count` is 0: report that no breakage events are recorded — either everything
is healthy, or the telemetry-enabled build isn't in use yet (the feature lives on
branch `feature/telemetry-and-loc-tooling` until merged/released).

Notes:
- `list()` in KV is eventually consistent, so the very latest event may lag up to
  ~60s. Mention this only if a just-sent event seems missing.
- To watch live instead of this snapshot: `cd worker && npx wrangler tail` and
  grep `"kind":"telemetry"`.
