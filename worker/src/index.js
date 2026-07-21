/**
 * Kaset Last.fm Proxy Worker
 *
 * A lightweight Cloudflare Worker that proxies Last.fm API requests.
 * The app sends unsigned requests; this Worker adds api_key and computes
 * api_sig (MD5) before forwarding to ws.audioscrobbler.com/2.0/.
 *
 * Environment variables (set via `wrangler secret put`):
 * - LASTFM_API_KEY: Last.fm API key
 * - LASTFM_SHARED_SECRET: Last.fm shared secret
 *
 * - Run "npm run dev" in your terminal to start a development server
 * - Open a browser tab at http://localhost:8787/ to see your worker in action
 * - Run "npm run deploy" to publish your worker
 *
 * Learn more at https://developers.cloudflare.com/workers/
 */

const LASTFM_API_URL = "https://ws.audioscrobbler.com/2.0/";

/**
 * Computes Last.fm API signature (MD5 of sorted params + shared secret).
 * See: https://www.last.fm/api/authspec#_8-signing-calls
 */
async function computeApiSig(params, secret) {
	const sortedKeys = Object.keys(params).sort();
	let sigString = "";
	for (const key of sortedKeys) {
		sigString += key + params[key];
	}
	sigString += secret;

	const encoder = new TextEncoder();
	const data = encoder.encode(sigString);
	const hashBuffer = await crypto.subtle.digest("MD5", data);
	const hashArray = Array.from(new Uint8Array(hashBuffer));
	return hashArray.map((b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * Makes a signed request to the Last.fm API.
 */
async function lastfmRequest(params, env, method = "POST") {
	// Add api_key to params
	params["api_key"] = env.LASTFM_API_KEY;
	params["format"] = "json";

	// Compute signature (format is excluded from sig per Last.fm spec)
	const sigParams = { ...params };
	delete sigParams["format"];
	const apiSig = await computeApiSig(sigParams, env.LASTFM_SHARED_SECRET);
	params["api_sig"] = apiSig;

	if (method === "GET") {
		const url = new URL(LASTFM_API_URL);
		for (const [key, value] of Object.entries(params)) {
			url.searchParams.set(key, value);
		}
		return fetch(url.toString());
	}

	// POST request
	const body = new URLSearchParams(params);
	return fetch(LASTFM_API_URL, {
		method: "POST",
		headers: { "Content-Type": "application/x-www-form-urlencoded" },
		body: body.toString(),
	});
}

/**
 * JSON error response helper.
 */
function errorResponse(message, status = 400) {
	return new Response(JSON.stringify({ error: message }), {
		status,
		headers: { "Content-Type": "application/json" },
	});
}

/**
 * JSON success response helper.
 */
function jsonResponse(obj, status = 200) {
	return new Response(JSON.stringify(obj), {
		status,
		headers: { "Content-Type": "application/json" },
	});
}

// KasetPlus supporter windows.
// A subscription payment grants ~34 days (each renewal payment extends it, so a
// cancelled membership lapses ~1 month after the last payment). A one-time tip
// grants 30 days.
const SUPPORT_SUB_GRANT_MS = 34 * 24 * 60 * 60 * 1000;
const SUPPORT_TIP_GRANT_MS = 30 * 24 * 60 * 60 * 1000;

/**
 * Ko-fi webhook: Ko-fi POSTs `application/x-www-form-urlencoded` with a `data`
 * field holding the event JSON. We record the supporter (keyed by email) in KV.
 * Configure this URL + its Verification Token in Ko-fi → Settings → Webhooks.
 */
async function handleKofiWebhook(request, env) {
	if (!env.SUPPORTERS) return errorResponse("Supporters KV not bound", 500);

	let data;
	try {
		const form = await request.formData();
		data = JSON.parse(form.get("data"));
	} catch {
		return errorResponse("Invalid Ko-fi payload");
	}

	if (!env.KOFI_VERIFICATION_TOKEN || data.verification_token !== env.KOFI_VERIFICATION_TOKEN) {
		return errorResponse("Bad verification token", 401);
	}

	const email = (data.email || "").trim().toLowerCase();
	// Ko-fi expects a 2xx even when we can't act on the event.
	if (!email) return jsonResponse({ ok: true, note: "no email in payload" });

	const isSubscription = data.type === "Subscription" || data.is_subscription_payment === true;
	const now = Date.now();
	let tier = isSubscription ? "subscription" : "onetime";
	let expiry = now + (isSubscription ? SUPPORT_SUB_GRANT_MS : SUPPORT_TIP_GRANT_MS);

	const existing = await env.SUPPORTERS.get(email, "json");
	if (existing) {
		// A later one-time tip must not downgrade an active subscription.
		if (existing.tier === "subscription" && existing.expiry > now && !isSubscription) {
			tier = "subscription";
			expiry = Math.max(existing.expiry, expiry);
		} else {
			expiry = Math.max(existing.expiry || 0, expiry);
		}
	}

	// Cumulative months of support = number of subscription payments seen
	// (one-time tips don't add months). Preserved across renewals.
	const months = (existing?.months || 0) + (isSubscription ? 1 : 0);
	const name = (data.from_name || existing?.name || "").toString().trim();

	await env.SUPPORTERS.put(email, JSON.stringify({
		tier,
		expiry,
		months,
		name,
		since: existing?.since || now,
		tierName: data.tier_name || null,
		updatedAt: now,
		lastTransactionId: data.kofi_transaction_id || null,
	}));

	return jsonResponse({ ok: true });
}

/**
 * Public supporters wall: active supporters only, **names only** (never emails),
 * newest payer first. Used by the app's Support sheet.
 */
async function handleKofiSupporters(request, env) {
	if (!env.SUPPORTERS) return errorResponse("Supporters KV not bound", 500);

	const now = Date.now();
	const supporters = [];
	let cursor;
	do {
		const page = await env.SUPPORTERS.list({ cursor });
		for (const key of page.keys) {
			const rec = await env.SUPPORTERS.get(key.name, "json");
			if (!rec || rec.expiry <= now) continue;
			supporters.push({
				name: (rec.name || "").trim() || "Anonymous",
				tier: rec.tier,
				months: rec.months || 0,
				updatedAt: Math.floor((rec.updatedAt || 0) / 1000),
			});
		}
		cursor = page.list_complete ? undefined : page.cursor;
	} while (cursor);

	supporters.sort((a, b) => b.updatedAt - a.updatedAt);
	return jsonResponse({ supporters });
}

/**
 * App-side verification: the app sends the email the user donated with; we
 * return whether it currently maps to an active supporter (and which tier).
 * Note: email-only (no code) — fine for a cosmetic status; harden with a code
 * in the Ko-fi message if abuse ever matters.
 */
async function handleKofiVerify(request, env) {
	if (!env.SUPPORTERS) return errorResponse("Supporters KV not bound", 500);

	const email = (new URL(request.url).searchParams.get("email") || "").trim().toLowerCase();
	if (!email) return errorResponse("Missing 'email' parameter");

	const rec = await env.SUPPORTERS.get(email, "json");
	if (rec && rec.expiry > Date.now()) {
		// Expiry as epoch SECONDS for the app.
		return jsonResponse({ supporter: true, tier: rec.tier, expiry: Math.floor(rec.expiry / 1000) });
	}
	return jsonResponse({ supporter: false });
}

/**
 * Anonymous breakage telemetry from the app. No PII — just an event name, a
 * small string detail, app/OS version, and a random install id. We only log it
 * (observability is enabled in wrangler.toml) so it shows up in Workers Logs /
 * `wrangler tail`. Filter with: `wrangler tail --format=pretty` and grep
 * `"kind":"telemetry"`.
 */
async function handleTelemetry(request, env) {
	// ponytail: log-only via observability; add KV/alerting if you outgrow the
	// dashboard's log retention.
	if (request.headers.get("X-Kaset-Telemetry") !== "1") {
		return errorResponse("bad request", 400);
	}
	let body;
	try {
		body = await request.json();
	} catch {
		return errorResponse("bad json", 400);
	}
	const event = String(body.event || "").slice(0, 64);
	if (!event) return errorResponse("missing event", 400);

	const detail =
		body.detail && typeof body.detail === "object" ? body.detail : {};
	console.log(
		JSON.stringify({
			kind: "telemetry",
			ts: new Date().toISOString(),
			event,
			detail,
			app: String(body.app || "?").slice(0, 32),
			os: String(body.os || "?").slice(0, 64),
			id: String(body.id || "?").slice(0, 40),
		}),
	);
	return new Response(JSON.stringify({ ok: true }), {
		status: 200,
		headers: { "Content-Type": "application/json" },
	});
}

export default {
	async fetch(request, env, ctx) {
		const url = new URL(request.url);
		const path = url.pathname;

		// --- KasetPlus support (Ko-fi) — independent of Last.fm config ---
		if (path === "/kofi/webhook" && request.method === "POST") {
			return handleKofiWebhook(request, env);
		}
		if (path === "/kofi/verify" && request.method === "GET") {
			return handleKofiVerify(request, env);
		}
		if (path === "/kofi/supporters" && request.method === "GET") {
			return handleKofiSupporters(request, env);
		}
		if (path === "/telemetry" && request.method === "POST") {
			return handleTelemetry(request, env);
		}

		// Validate env vars are configured (Last.fm routes only)
		if (!env.LASTFM_API_KEY || !env.LASTFM_SHARED_SECRET) {
			return errorResponse("Server misconfigured: missing API credentials", 500);
		}

		// --- Health Check ---
		if (path === "/health" && request.method === "GET") {
			return new Response(
				JSON.stringify({ status: "ok", service: "kaset-lastfm-proxy" }),
				{ status: 200, headers: { "Content-Type": "application/json" } },
			);
		}

		// --- GET /auth/token — Request an auth token from Last.fm ---
		if (path === "/auth/token" && request.method === "GET") {
			const params = { method: "auth.getToken" };
			const response = await lastfmRequest(params, env, "GET");
			const data = await response.text();
			return new Response(data, {
				status: response.status,
				headers: { "Content-Type": "application/json" },
			});
		}

		// --- GET /auth/session?token=X — Exchange token for session key ---
		if (path === "/auth/session" && request.method === "GET") {
			const token = url.searchParams.get("token");
			if (!token) {
				return errorResponse("Missing 'token' parameter");
			}

			const params = { method: "auth.getSession", token };
			const response = await lastfmRequest(params, env, "GET");
			const data = await response.text();
			return new Response(data, {
				status: response.status,
				headers: { "Content-Type": "application/json" },
			});
		}

		// --- POST /auth/validate — Validate an existing session key ---
		if (path === "/auth/validate" && request.method === "POST") {
			let body;
			try {
				body = await request.json();
			} catch {
				return errorResponse("Invalid JSON body");
			}

			if (!body.sk) {
				return errorResponse("Missing required field: sk");
			}

			const params = { method: "user.getInfo", sk: body.sk };
			const response = await lastfmRequest(params, env, "GET");
			const data = await response.text();
			return new Response(data, {
				status: response.status,
				headers: { "Content-Type": "application/json" },
			});
		}

		// --- GET /auth/url?token=X — Return the Last.fm auth URL ---
		if (path === "/auth/url" && request.method === "GET") {
			const token = url.searchParams.get("token");
			if (!token) {
				return errorResponse("Missing 'token' parameter");
			}

			const authUrl = `https://www.last.fm/api/auth/?api_key=${env.LASTFM_API_KEY}&token=${token}`;
			return new Response(JSON.stringify({ url: authUrl }), {
				status: 200,
				headers: { "Content-Type": "application/json" },
			});
		}

		// --- POST /nowplaying — Send a "now playing" update ---
		if (path === "/nowplaying" && request.method === "POST") {
			let body;
			try {
				body = await request.json();
			} catch {
				return errorResponse("Invalid JSON body");
			}

			if (!body.sk || !body.artist || !body.track) {
				return errorResponse("Missing required fields: sk, artist, track");
			}

			const params = {
				method: "track.updateNowPlaying",
				sk: body.sk,
				artist: body.artist,
				track: body.track,
			};

			if (body.album) params["album"] = body.album;
			if (body.duration) params["duration"] = String(body.duration);

			const response = await lastfmRequest(params, env);
			const data = await response.text();
			return new Response(data, {
				status: response.status,
				headers: { "Content-Type": "application/json" },
			});
		}

		// --- POST /scrobble — Submit scrobbles (up to 50 per batch) ---
		if (path === "/scrobble" && request.method === "POST") {
			let body;
			try {
				body = await request.json();
			} catch {
				return errorResponse("Invalid JSON body");
			}

			if (!body.sk || !body.scrobbles || !Array.isArray(body.scrobbles)) {
				return errorResponse("Missing required fields: sk, scrobbles");
			}

			if (body.scrobbles.length === 0) {
				return errorResponse("scrobbles array must not be empty");
			}

			if (body.scrobbles.length > 50) {
				return errorResponse("Maximum 50 scrobbles per batch");
			}

			// Build indexed params per Last.fm batch scrobble format
			const params = {
				method: "track.scrobble",
				sk: body.sk,
			};

			for (let i = 0; i < body.scrobbles.length; i++) {
				const s = body.scrobbles[i];
				if (!s.artist || !s.track || !s.timestamp) {
					return errorResponse(
						`Scrobble at index ${i} missing required fields: artist, track, timestamp`,
					);
				}
				params[`artist[${i}]`] = s.artist;
				params[`track[${i}]`] = s.track;
				params[`timestamp[${i}]`] = String(s.timestamp);
				if (s.album) params[`album[${i}]`] = s.album;
				if (s.duration) params[`duration[${i}]`] = String(s.duration);
			}

			const response = await lastfmRequest(params, env);
			const data = await response.text();
			return new Response(data, {
				status: response.status,
				headers: { "Content-Type": "application/json" },
			});
		}

		// --- 404 ---
		return errorResponse("Not found", 404);
	},
};
