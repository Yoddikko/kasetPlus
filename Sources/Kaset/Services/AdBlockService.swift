import Foundation
import WebKit

/// Compiles and manages WKContentRuleList for ad/tracker blocking,
/// plus provides an auto-skip script for YouTube in-video ads.
@MainActor
enum AdBlockService {
    /// Identifier used for the compiled rule list.
    private static let ruleListID = "com.kaset.adblock"

    /// Cached compiled rule list — nil until compilation completes.
    private(set) static var compiledRuleList: WKContentRuleList?

    // MARK: - Content Blocking Rules

    /// JSON rule list targeting common ad-serving and tracking domains,
    /// plus YouTube-specific ad-related API endpoints.
    /// Uses simple substring matching.
    static let contentRulesJSON: String = {
        let domains = [
            // Google ad infrastructure
            "doubleclick.net",
            "googleadservices.com",
            "googlesyndication.com",
            "pagead2.googlesyndication.com",
            "adservice.google.com",
            "ads.youtube.com",
            "partnerad.l.google.com",
            "ad.doubleclick.net",
            "googleads.g.doubleclick.net",
            "pubads.g.doubleclick.net",
            "securepubads.g.doubleclick.net",
            "static.doubleclick.net",
            "imasdk.googleapis.com",
            "video-ad-stats.googlesyndication.com",
            // YouTube ad / tracking endpoints
            "youtube.com/api/stats/ads",
            "youtube.com/ptracking",
            "youtube.com/pagead/",
            // Analytics / tracking
            "google-analytics.com",
            "googletagmanager.com",
            "facebook.com/tr",
            "scorecardresearch.com",
            "hotjar.com",
            "clarity.ms",
            // Ad exchanges / networks
            "adnxs.com",
            "adsrvr.org",
            "criteo.com",
            "criteo.net",
            "outbrain.com",
            "taboola.com",
            "amazon-adsystem.com",
            "rubiconproject.com",
            "pubmatic.com",
            "openx.net",
            "moatads.com",
            "bidswitch.net",
            "casalemedia.com",
            "indexww.com",
            "contextweb.com",
            "sovrn.com",
        ]

        let rules = domains.map { domain in
            """
            {"trigger":{"url-filter":"\(domain)"},"action":{"type":"block"}}
            """
        }

        return "[" + rules.joined(separator: ",") + "]"
    }()

    // MARK: - Compilation

    /// Compiles the content blocking rules. Call once at startup.
    static func compile() async {
        guard compiledRuleList == nil else { return }

        do {
            compiledRuleList = try await WKContentRuleListStore.default()
                .compileContentRuleList(
                    forIdentifier: ruleListID,
                    encodedContentRuleList: contentRulesJSON
                )
            DiagnosticsLogger.app.info("AdBlock: rules compiled successfully")
        } catch {
            DiagnosticsLogger.app.error("AdBlock: compilation failed — \(error.localizedDescription)")
        }
    }

    /// Applies the compiled rule list to a WebView configuration.
    static func apply(to configuration: WKWebViewConfiguration) {
        guard SettingsManager.shared.adBlockEnabled,
              let ruleList = compiledRuleList
        else { return }
        configuration.userContentController.add(ruleList)
    }

    // MARK: - YouTube Ad Auto-Skip Script

    /// JS injected into YouTube watch pages at document-start.
    ///
    /// Proven approach (YouTube DeAd, 2025-2026): replace ad-related property
    /// names in RAW JSON strings BEFORE YouTube's player parses them. This
    /// prevents ads at the API level — no DOM polling, no skip-button clicking
    /// needed as primary defense. Aggressive ad-skip is kept as fallback.
    ///
    /// Key insight: renaming `"adPlacements"` → `"blockedPlacements"` in
    /// the JSON string means YouTube's code finds `undefined` when reading
    /// `playerResponse.adPlacements`, which is the same as "no ads for this
    /// video." The player handles this gracefully.
    static let adBlockScript: String = {
        """
        (function() {
            'use strict';

            // ── Ad keys to rename in raw JSON ─────────────────
            // Replaces the QUOTED key (e.g. "adPlacements") only when it
            // appears as a JSON property name, not in arbitrary text.
            // Uses string-replace on the raw response TEXT — much faster
            // and more reliable than recursive object pruning.
            var AD_RENAMES = [
                ['"adPlacements"', '"blockedPlacements"'],
                ['"adSlots"', '"blockedSlots"'],
                ['"playerAds"', '"blockedPlayerAds"'],
                ['"adBreakHeartbeatParams"', '"blockedAdBreakHeartbeat"'],
                ['"adPodInfo"', '"blockedAdPodInfo"'],
                ['"adPlaybackInfo"', '"blockedAdPlaybackInfo"'],
                ['"adSlotsInfo"', '"blockedAdSlotsInfo"'],
                ['"requestAd"', '"blockedRequestAd"'],
                ['"companionAds"', '"blockedCompanionAds"'],
                ['"adPlacementConfig"', '"blockedAdPlacementConfig"'],
            ];

            function stripAds(text) {
                if (typeof text !== 'string' || !text) return text;
                for (var i = 0; i < AD_RENAMES.length; i++) {
                    // Only replace if the original key actually exists
                    if (text.indexOf(AD_RENAMES[i][0]) !== -1) {
                        text = text.split(AD_RENAMES[i][0]).join(AD_RENAMES[i][1]);
                    }
                }
                return text;
            }

            // ── 1. Property trap on ytInitialPlayerResponse ──
            // YouTube embeds initial ad data via inline <script>.
            // This setter fires when the page assigns to the global,
            // BEFORE YouTube's player reads it.
            Object.defineProperty(window, 'ytInitialPlayerResponse', {
                get: function() { return this.__ytIPR; },
                set: function(data) {
                    if (data) {
                        try {
                            this.__ytIPR = JSON.parse(stripAds(JSON.stringify(data)));
                        } catch(e) { this.__ytIPR = data; }
                    } else {
                        this.__ytIPR = data;
                    }
                },
                configurable: true
            });

            // Also trap ytInitialData (used on some YouTube pages)
            Object.defineProperty(window, 'ytInitialData', {
                get: function() { return this.__ytID; },
                set: function(data) {
                    if (data) {
                        try {
                            this.__ytID = JSON.parse(stripAds(JSON.stringify(data)));
                        } catch(e) { this.__ytID = data; }
                    } else {
                        this.__ytID = data;
                    }
                },
                configurable: true
            });

            // ── 2. fetch() override ──────────────────────────
            var _fetch = window.fetch;
            window.fetch = function(input, init) {
                var url = typeof input === 'string' ? input : (input && input.url ? input.url : '');
                if (url && (url.indexOf('youtubei/v1') !== -1 || url.indexOf('/watch') !== -1)) {
                    return _fetch.apply(this, arguments).then(function(resp) {
                        return resp.text().then(function(body) {
                            return new Response(stripAds(body), {
                                status: resp.status,
                                statusText: resp.statusText,
                                headers: resp.headers
                            });
                        });
                    });
                }
                return _fetch.apply(this, arguments);
            };

            // ── 3. XMLHttpRequest override ──────────────────
            var _xhrOpen = XMLHttpRequest.prototype.open;
            var _xhrSend = XMLHttpRequest.prototype.send;
            XMLHttpRequest.prototype.open = function(method, url) {
                this.__kURL = typeof url === 'string' ? url : '';
                return _xhrOpen.apply(this, arguments);
            };
            XMLHttpRequest.prototype.send = function() {
                var self = this;
                var url = self.__kURL || '';
                if (url && (url.indexOf('youtubei/v1') !== -1 || url.indexOf('/watch') !== -1)) {
                    var listener = function() {
                        if (self.readyState === 4 && self.responseText) {
                            try {
                                Object.defineProperty(self, 'responseText',
                                    {value: stripAds(self.responseText), writable: true});
                                Object.defineProperty(self, 'response',
                                    {value: stripAds(self.response), writable: true});
                            } catch(e) {}
                        }
                    };
                    self.addEventListener('readystatechange', listener);
                }
                return _xhrSend.apply(this, arguments);
            };

            // ── 4. Aggressive ad-skip fallback ───────────────
            // Handles any ad that slips through (e.g. server-side ad stitching).
            var wasAd = false;
            setInterval(function() {
                try {
                    var player = document.getElementById('movie_player');
                    if (!player) return;
                    var isAd = player.classList.contains('ad-showing');
                    var video = document.querySelector('#movie_player video') || document.querySelector('video');
                    if (!video) return;
                    if (isAd) {
                        wasAd = true;
                        var btns = document.querySelectorAll(
                            '.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button,' +
                            '.ytp-ad-skip-button-container button, button[aria-label*=\"Skip\"]'
                        );
                        btns.forEach(function(b) { b.click(); });
                        document.querySelectorAll('.ytp-ad-overlay-close-button').forEach(function(o) { o.click(); });
                        video.playbackRate = 16;
                        video.muted = true;
                    } else if (wasAd) {
                        wasAd = false;
                        video.playbackRate = 1;
                        if (window.__kasetTargetVolume > 0) video.muted = false;
                    }
                } catch(e) {}
            }, 150);
        })();
        """
    }()
}
