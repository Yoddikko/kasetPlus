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
			if (key.name.startsWith("tel:")) continue; // telemetry events share this KV
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

	const record = {
		ts: new Date().toISOString(),
		event,
		detail: body.detail && typeof body.detail === "object" ? body.detail : {},
		app: String(body.app || "?").slice(0, 32),
		os: String(body.os || "?").slice(0, 64),
		id: String(body.id || "?").slice(0, 40),
	};
	// Show up in Workers Logs / `wrangler tail`.
	console.log(JSON.stringify({ kind: "telemetry", ...record }));
	// Persist for the /telemetry/recent view. 7-day TTL auto-cleans, so there
	// are no manual deletes and none of the stale-cache ghosts we hit before.
	// Stored in metadata so the recent view is a single list() with no gets.
	if (env.SUPPORTERS) {
		try {
			const key = `tel:${Date.now().toString().padStart(15, "0")}:${crypto.randomUUID().slice(0, 8)}`;
			// ponytail: record is small; metadata ceiling is 1 KiB, fine here.
			await env.SUPPORTERS.put(key, "1", {
				expirationTtl: 604800,
				metadata: record,
			});
		} catch (e) {
			console.log(JSON.stringify({ kind: "telemetry-store-error", error: String(e) }));
		}
	}
	return new Response(JSON.stringify({ ok: true }), {
		status: 200,
		headers: { "Content-Type": "application/json" },
	});
}

/**
 * Returns recently stored telemetry events (newest first) for the
 * `check-telemetry` skill / a quick browser check. No PII; anonymized already.
 */
async function handleTelemetryRecent(request, env) {
	if (!env.SUPPORTERS) return errorResponse("KV not bound", 500);
	// Maintainer-only: requires the TELEMETRY_TOKEN secret. Fails closed if the
	// secret isn't set, so the endpoint is never accidentally public.
	if (!env.TELEMETRY_TOKEN || request.headers.get("X-Telemetry-Token") !== env.TELEMETRY_TOKEN) {
		return errorResponse("unauthorized", 401);
	}
	const { keys } = await env.SUPPORTERS.list({ prefix: "tel:", limit: 1000 });
	const events = keys
		.map((k) => k.metadata)
		.filter(Boolean)
		.reverse();
	return jsonResponse({ count: events.length, events });
}

// --- Crowdin localization progress (powers the README status badges) ---
const CROWDIN_PROJECT_ID = 914637;
const CROWDIN_LANG_NAMES = {
	ar: "Arabic", de: "German", en: "English", "es-ES": "Spanish", fr: "French",
	id: "Indonesian", it: "Italian", ko: "Korean", nl: "Dutch", pl: "Polish",
	"pt-PT": "Portuguese", "pt-BR": "Portuguese (BR)", ru: "Russian", "sv-SE": "Swedish",
	tr: "Turkish", uk: "Ukrainian", ja: "Japanese", "zh-CN": "Chinese (Simpl.)",
	"zh-TW": "Chinese (Trad.)", cs: "Czech", da: "Danish", fi: "Finnish", el: "Greek",
	he: "Hebrew", hu: "Hungarian", no: "Norwegian", ro: "Romanian", sr: "Serbian",
	vi: "Vietnamese", ca: "Catalan", af: "Afrikaans",
};

/**
 * Fetches `{ crowdinLangId: translationProgress }` from the Crowdin API, cached
 * at the edge for 30 min so 30 badge requests = at most one upstream call.
 */
async function getCrowdinProgress(env, ctx) {
	const cache = caches.default;
	const key = new Request("https://internal.cache/crowdin-progress-v2");
	const cached = await cache.match(key);
	if (cached) return cached.json();
	const res = await fetch(
		`https://api.crowdin.com/api/v2/projects/${CROWDIN_PROJECT_ID}/languages/progress?limit=100`,
		{ headers: { Authorization: `Bearer ${env.CROWDIN_TOKEN}` } },
	);
	if (!res.ok) throw new Error(`crowdin ${res.status}`);
	const json = await res.json();
	const out = {};
	for (const row of json.data || []) {
		out[row.data.languageId] = { tr: row.data.translationProgress, ap: row.data.approvalProgress };
	}
	const store = new Response(JSON.stringify(out), {
		headers: { "content-type": "application/json", "cache-control": "public, max-age=1800" },
	});
	if (ctx) ctx.waitUntil(cache.put(key, store.clone()));
	return out;
}

async function handleCrowdinProgress(env, ctx) {
	if (!env.CROWDIN_TOKEN) return errorResponse("Crowdin token not set", 500);
	try {
		const out = await getCrowdinProgress(env, ctx);
		return new Response(JSON.stringify(out), {
			headers: {
				"content-type": "application/json",
				"access-control-allow-origin": "*",
				"cache-control": "public, max-age=1800",
			},
		});
	} catch (e) {
		return errorResponse(`crowdin: ${e}`, 502);
	}
}

async function handleCrowdinBadge(lang, env, ctx) {
	// Shields.io endpoint schema: https://shields.io/badges/endpoint-badge
	if (!env.CROWDIN_TOKEN) return errorResponse("Crowdin token not set", 500);
	const label = CROWDIN_LANG_NAMES[lang] || lang;
	let body;
	try {
		const p = (await getCrowdinProgress(env, ctx))[lang];
		if (p == null) {
			body = { schemaVersion: 1, label, message: "n/a", color: "lightgrey" };
		} else {
			const tr = Math.round(p.tr || 0);
			const ap = Math.round(p.ap || 0);
			// tr = % translated, ap = % verified/approved (always shown for transparency)
			body = {
				schemaVersion: 1,
				label,
				message: `${tr}% · ✓${ap}%`,
				// color follows the verified (✓) %, not the translated total
				color: ap >= 90 ? "brightgreen" : ap >= 50 ? "green" : ap >= 20 ? "yellow" : ap > 0 ? "orange" : "lightgrey",
			};
		}
	} catch {
		body = { schemaVersion: 1, label, message: "error", color: "lightgrey", isError: true };
	}
	return new Response(JSON.stringify(body), {
		headers: {
			"content-type": "application/json",
			"access-control-allow-origin": "*",
			"cache-control": "public, max-age=1800",
		},
	});
}

// --- Crowdin translators (live SVG credit list for the README) ---
const TRANSLATOR_ROLES = {
	// role id -> [label, color] (color readable on light + dark)
	proofreader: ["Proofreader", "#2da44f"],
	language_coordinator: ["Coordinator", "#8250df"],
	translator: ["Translator", "#0969da"],
};
const TRANSLATOR_ROLE_ORDER = ["proofreader", "language_coordinator", "translator"];

// Crowdin language id -> ISO country code (for the flag + short code).
const LANG_FLAG_COUNTRY = {
	it: "IT", de: "DE", fr: "FR", es: "ES", "es-ES": "ES", pt: "PT", "pt-PT": "PT", "pt-BR": "BR",
	nl: "NL", pl: "PL", ru: "RU", uk: "UA", sv: "SE", "sv-SE": "SE", ar: "SA", ko: "KR", tr: "TR",
	id: "ID", ja: "JP", "zh-CN": "CN", "zh-Hans": "CN", "zh-TW": "TW", "zh-Hant": "TW",
	cs: "CZ", da: "DK", fi: "FI", el: "GR", he: "IL", hu: "HU", no: "NO", nb: "NO", ro: "RO",
	sr: "RS", vi: "VN", ca: "ES", af: "ZA", en: "GB",
};

function flagAndCode(langCode) {
	const cc = LANG_FLAG_COUNTRY[langCode] || (langCode.split("-").pop() || langCode).slice(0, 2).toUpperCase();
	const flag = [...cc].map((ch) => String.fromCodePoint(0x1f1e6 + ch.charCodeAt(0) - 65)).join("");
	return `${flag} ${cc}`;
}

async function getCrowdinMembers(env, ctx) {
	const cache = caches.default;
	const key = new Request("https://internal.cache/crowdin-members-v3");
	const cached = await cache.match(key);
	if (cached) return cached.json();
	const res = await fetch(
		`https://api.crowdin.com/api/v2/projects/${CROWDIN_PROJECT_ID}/members?limit=100`,
		{ headers: { Authorization: `Bearer ${env.CROWDIN_TOKEN}` } },
	);
	if (!res.ok) throw new Error(`crowdin ${res.status}`);
	const json = await res.json();
	const members = (json.data || []).map((m) => {
		const roleObjs = m.data.roles || [];
		const langs = new Set();
		let allLang = false;
		for (const r of roleObjs) {
			const perm = r.permissions || {};
			if (perm.allLanguages) allLang = true;
			const access = perm.languagesAccess;
			if (access && typeof access === "object" && !Array.isArray(access)) {
				for (const lg of Object.keys(access)) langs.add(lg);
			}
		}
		const roles = roleObjs.map((r) => r.name || r).filter(Boolean);
		return {
			id: String(m.data.id),
			name: m.data.fullName || m.data.username || "?",
			avatarUrl: m.data.avatarUrl || null,
			roles,
			langs: [...langs],
			allLang,
			isOwner: roles.includes("owner"),
		};
	});
	const store = new Response(JSON.stringify(members), {
		headers: { "content-type": "application/json", "cache-control": "public, max-age=1800" },
	});
	if (ctx) ctx.waitUntil(cache.put(key, store.clone()));
	return members;
}

// Per-user contribution (approved/translated words) via the async Report API.
async function getCrowdinContributions(env, ctx) {
	const cache = caches.default;
	const key = new Request("https://internal.cache/crowdin-contrib-v1");
	const cached = await cache.match(key);
	if (cached) return cached.json();
	const base = `https://api.crowdin.com/api/v2/projects/${CROWDIN_PROJECT_ID}/reports`;
	const auth = { Authorization: `Bearer ${env.CROWDIN_TOKEN}` };
	const gen = await fetch(base, {
		method: "POST",
		headers: { ...auth, "Content-Type": "application/json" },
		body: JSON.stringify({ name: "top-members", schema: { unit: "words", format: "json" } }),
	});
	const genData = (await gen.json()).data;
	const id = genData?.identifier;
	if (!id) throw new Error("report generation failed");
	let status = genData.status;
	for (let i = 0; i < 12 && status !== "finished"; i++) {
		await new Promise((r) => setTimeout(r, 600));
		status = (await (await fetch(`${base}/${id}`, { headers: auth })).json()).data?.status;
		if (status === "failed") throw new Error("report failed");
	}
	if (status !== "finished") throw new Error("report timeout");
	const url = (await (await fetch(`${base}/${id}/download`, { headers: auth })).json()).data?.url;
	const report = await (await fetch(url)).json();
	const map = {};
	for (const u of report.data || []) {
		map[String(u.user.id)] = { approved: u.approved || 0, translated: u.translated || 0 };
	}
	const store = new Response(JSON.stringify(map), {
		headers: { "content-type": "application/json", "cache-control": "public, max-age=3600" },
	});
	if (ctx) ctx.waitUntil(cache.put(key, store.clone()));
	return map;
}

// Fetches an avatar and inlines it as a base64 data URI (external <image> URLs
// don't load inside an SVG rendered via GitHub's <img>).
async function fetchAvatarDataURI(url) {
	if (!url) return null;
	try {
		const res = await fetch(url, { cf: { cacheTtl: 86400, cacheEverything: true } });
		if (!res.ok) return null;
		const bytes = new Uint8Array(await res.arrayBuffer());
		let bin = "";
		for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
		return `data:${res.headers.get("content-type") || "image/png"};base64,${btoa(bin)}`;
	} catch {
		return null;
	}
}

function xmlEscape(s) {
	return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

function renderTranslatorsSVG(translators) {
	const W = 520, rowH = 46, padX = 16, padY = 12;
	const H = padY * 2 + Math.max(translators.length, 1) * rowH;
	const head = `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="${W}" height="${H}" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif">` +
		`<style>.name{fill:#24292f;font-weight:600;font-size:14px}.sub{fill:#57606a;font-size:12px}.count{fill:#2da44f;font-size:13px;font-weight:600}@media(prefers-color-scheme:dark){.name{fill:#e6edf3}.sub{fill:#8b949e}}</style>`;
	if (translators.length === 0) {
		return head + `<text x="${padX}" y="${padY + 24}" class="sub">No translators yet — be the first!</text></svg>`;
	}
	const body = translators
		.map((m, i) => {
			const top = padY + i * rowH;
			const cy = top + rowH / 2;
			const roleColor = TRANSLATOR_ROLES[m.roles[0]][1];
			const langText = m.langs.length ? m.langs.map(flagAndCode).join("  ") : (m.allLang ? "🌐 all" : "");
			const roleText = m.roles.map((r) => TRANSLATOR_ROLES[r][0]).join(" · ");
			const sub = [langText, roleText].filter(Boolean).join("  ·  ");
			const avatar = m.avatar
				? `<clipPath id="c${i}"><circle cx="${padX + 16}" cy="${cy}" r="16"/></clipPath>` +
					`<image xlink:href="${m.avatar}" x="${padX}" y="${cy - 16}" width="32" height="32" clip-path="url(#c${i})"/>`
				: `<circle cx="${padX + 16}" cy="${cy}" r="16" fill="${roleColor}"/>` +
					`<text x="${padX + 16}" y="${cy + 5}" text-anchor="middle" fill="#fff" font-size="14" font-weight="600">${xmlEscape((m.name[0] || "?").toUpperCase())}</text>`;
			const count = m.approved != null
				? `<text x="${W - padX}" y="${cy + 5}" text-anchor="end" class="count">${m.approved} approved</text>`
				: "";
			return (
				avatar +
				`<text x="${padX + 44}" y="${top + 20}" class="name">${xmlEscape(m.name)}</text>` +
				`<text x="${padX + 44}" y="${top + 37}" class="sub">${xmlEscape(sub)}</text>` +
				count
			);
		})
		.join("");
	return head + body + `</svg>`;
}

async function handleCrowdinTranslators(env, ctx) {
	if (!env.CROWDIN_TOKEN) return errorResponse("Crowdin token not set", 500);
	const cache = caches.default;
	const cacheKey = new Request("https://internal.cache/translators-svg-v1");
	const hit = await cache.match(cacheKey);
	if (hit) return hit;
	let svg;
	try {
		const members = await getCrowdinMembers(env, ctx);
		let contrib = {};
		try {
			contrib = await getCrowdinContributions(env, ctx);
		} catch {
			/* report is optional — still render the list without word counts */
		}
		const translators = members
			.filter((m) => !m.isOwner)
			.map((m) => ({ ...m, roles: TRANSLATOR_ROLE_ORDER.filter((r) => m.roles.includes(r)) }))
			.filter((m) => m.roles.length > 0)
			.sort((a, b) =>
				TRANSLATOR_ROLE_ORDER.indexOf(a.roles[0]) - TRANSLATOR_ROLE_ORDER.indexOf(b.roles[0]) ||
				a.name.localeCompare(b.name),
			);
		const enriched = await Promise.all(
			translators.map(async (m) => ({
				...m,
				approved: m.id in contrib ? contrib[m.id].approved : null,
				avatar: await fetchAvatarDataURI(m.avatarUrl),
			})),
		);
		svg = renderTranslatorsSVG(enriched);
	} catch {
		svg = renderTranslatorsSVG([]);
	}
	const resp = new Response(svg, {
		headers: {
			"content-type": "image/svg+xml; charset=utf-8",
			"access-control-allow-origin": "*",
			"cache-control": "public, max-age=3600",
		},
	});
	if (ctx) ctx.waitUntil(cache.put(cacheKey, resp.clone()));
	return resp;
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
		if (path === "/telemetry/recent" && request.method === "GET") {
			return handleTelemetryRecent(request, env);
		}
		if (path === "/crowdin/progress" && request.method === "GET") {
			return handleCrowdinProgress(env, ctx);
		}
		if (path === "/crowdin/translators.svg" && request.method === "GET") {
			return handleCrowdinTranslators(env, ctx);
		}
		if (path.startsWith("/crowdin/badge/") && request.method === "GET") {
			return handleCrowdinBadge(decodeURIComponent(path.slice(15)), env, ctx);
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
