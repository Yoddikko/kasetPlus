# Kaset Last.fm Proxy Worker

A lightweight [Cloudflare Worker](https://developers.cloudflare.com/workers/) that proxies Last.fm API requests for the Kaset macOS app. The app sends unsigned requests; the Worker adds `api_key` and computes `api_sig` (MD5) before forwarding to Last.fm.

## Why a proxy?

The Last.fm API requires a shared secret for signing requests. Embedding secrets in the app binary is a security risk. This Worker keeps the API key and shared secret server-side — the app only needs to know the Worker URL.

## Setup

```bash
cd worker
npm install
```

### Set secrets

Get your API key and shared secret from [last.fm/api/account](https://www.last.fm/api/account), then:

```bash
npx wrangler secret put LASTFM_API_KEY
npx wrangler secret put LASTFM_SHARED_SECRET
```

### Local development

```bash
npm run dev
# Worker runs at http://localhost:8787
```

### Deploy

```bash
npm run deploy
```

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Health check |
| `/auth/token` | GET | Get a Last.fm auth token |
| `/auth/url?token=X` | GET | Get the Last.fm authorization URL |
| `/auth/session?token=X` | GET | Exchange token for session key |
| `/auth/validate?sk=X` | GET | Validate an existing session key |
| `/nowplaying` | POST | Update "now playing" status |
| `/scrobble` | POST | Submit scrobbles (up to 50 per batch) |

### POST /nowplaying

```json
{
  "sk": "session-key",
  "artist": "The Weeknd",
  "track": "Blinding Lights",
  "album": "After Hours",
  "duration": 200
}
```

### POST /scrobble

```json
{
  "sk": "session-key",
  "scrobbles": [
    {
      "artist": "The Weeknd",
      "track": "Blinding Lights",
      "timestamp": 1708560000,
      "album": "After Hours",
      "duration": 200
    }
  ]
}
```

## Auth flow

1. App calls `GET /auth/token` → receives a token
2. App calls `GET /auth/url?token=X` → gets the Last.fm auth URL
3. User authorizes in browser
4. App polls `GET /auth/session?token=X` → receives permanent session key

## KasetPlus support (Ko-fi supporter status)

The same Worker also records Ko-fi supporters and answers the app's status
check. Two endpoints:

- `POST /kofi/webhook` — Ko-fi calls this on every tip / membership payment.
- `GET  /kofi/verify?email=<email>` — the app calls this to check status.

### One-time setup (all in `worker/`)

1. **Create the KV store** (holds supporters, keyed by email):
   ```bash
   npx wrangler kv namespace create SUPPORTERS
   ```
   Paste the printed `id` into `wrangler.toml`'s `[[kv_namespaces]]` block
   (replacing `REPLACE_WITH_KV_NAMESPACE_ID`).

2. **Ko-fi webhook**: Ko-fi → **Settings → Advanced → Webhooks**. Set the URL to
   `https://<your-worker>.workers.dev/kofi/webhook` and copy the **Verification
   Token** shown there.

3. **Store the token** as a secret:
   ```bash
   npx wrangler secret put KOFI_VERIFICATION_TOKEN   # paste the token from step 2
   ```

4. **Deploy**:
   ```bash
   npx wrangler deploy
   ```

5. **Point the app at your Worker** (once): add to the app's `Info.plist`
   ```xml
   <key>SupportWorkerURL</key>
   <string>https://<your-worker>.workers.dev</string>
   ```
   (If you already run your own Worker for Last.fm via `LastFMWorkerURL`, the app
   reuses that automatically and this step is optional.)

### Test the chain
- Ko-fi has a "Send test webhook" button — or make a €1 tip.
- `curl "https://<your-worker>.workers.dev/kofi/verify?email=you@example.com"`
  → `{"supporter":true,"tier":"onetime","expiry":...}`.
- In the app: **Support the project → "Already supported? Verify"** → enter the
  same email → the button becomes **Supporter**.

### How status is decided
- **Subscription** payment → supporter for ~34 days; each renewal extends it, so
  a cancelled membership lapses ~1 month after the last payment.
- **One-time tip** → supporter for 30 days.
- The app re-checks the saved email on launch, so lapses drop off automatically.

Verification is **email-only** (no code) — fine for a cosmetic badge. If abuse
ever matters, ask supporters to include a code in the Ko-fi message and check it
in `handleKofiVerify`.
