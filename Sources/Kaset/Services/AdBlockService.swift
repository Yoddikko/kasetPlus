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

    /// JS injected into YouTube watch pages at document-start, in the page's
    /// main world (the legacy `WKUserScript` init injects there), before
    /// YouTube's own scripts run — only when ad blocking is enabled.
    ///
    /// Strips YouTube's ad scheduling (`adPlacements`/`playerAds`/…) from the
    /// player response. Earlier naive attempts broke playback because YouTube's
    /// #1 anti-adblock check is `Function.prototype.toString` on our hooked
    /// natives: a patched `fetch`/`JSON.parse` whose source isn't `[native
    /// code]` is detected and the player is deliberately killed. So we install
    /// a **toString mask** (WeakMap → each hook's original native source) so the
    /// hooks stay invisible, and prune ad fields *in place* (no object-identity
    /// change). The DOM Skip-button click stays as a backstop. Server-side
    /// (SSAI) ads are stitched into the stream and can't be removed here.
    static let adBlockScript: String = {
        """
        (function() {
            'use strict';

            // ── toString mask: keep hooked natives reporting [native code] ──
            var _toString = Function.prototype.toString;
            var _masks = new WeakMap();
            function mask(hooked, original) { try { _masks.set(hooked, original); } catch (e) {} return hooked; }
            var patchedToString = function toString() {
                var orig = _masks.get(this);
                return _toString.call(orig !== undefined ? orig : this);
            };
            mask(patchedToString, _toString);
            try {
                Object.defineProperty(Function.prototype, 'toString', {
                    value: patchedToString, writable: true, configurable: true
                });
            } catch (e) { Function.prototype.toString = patchedToString; }

            // ── ad-field pruning helper (in place: preserves object identity,
            //    which YouTube's player relies on — a deep copy desynced it) ──
            var AD_KEYS = ['adPlacements', 'playerAds', 'adSlots', 'adBreakHeartbeatParams', 'adPlacementConfig'];
            function pruneObject(o) {
                if (!o || typeof o !== 'object') return o;
                for (var i = 0; i < AD_KEYS.length; i++) {
                    if (AD_KEYS[i] in o) { try { delete o[AD_KEYS[i]]; } catch (e) { o[AD_KEYS[i]] = undefined; } }
                }
                if (o.playerResponse && typeof o.playerResponse === 'object') { pruneObject(o.playerResponse); }
                return o;
            }

            // ── Prune the inline ytInitialPlayerResponse (kills the pre/mid-roll
            //    at the source on every full-page watch load). We deliberately do
            //    NOT rewrite the fetched youtubei/v1/player response: rebuilding
            //    that Response reliably blanks the player. Anything the refetch
            //    still schedules is handled by the DOM backstop below. ──
            var _ipr;
            try {
                Object.defineProperty(window, 'ytInitialPlayerResponse', {
                    get: function() { return _ipr; },
                    set: function(v) { _ipr = pruneObject(v); },
                    configurable: true
                });
            } catch (e) {}

            // ── DOM backstop for ads that still surface (e.g. SSAI): mute the
            //       ad and click YouTube's own Skip the instant it appears.
            //       Measured dead ends (all reverted): forcing playbackRate does
            //       nothing — YouTube resets the ad to 1x every frame; seeking to
            //       the clip end restarts the ad from 0; and re-running the
            //       extraction on ad end blanked the content during the video
            //       swap. So we only mute + click Skip; the content re-appears on
            //       its own via the extraction's DOM observer. ──
            var wasAd = false;
            function killAd() {
                try {
                    var mp = document.getElementById('movie_player');
                    var video = document.querySelector('#movie_player video') || document.querySelector('video');
                    if (!video) { return; }
                    var isAd = !!(mp && mp.classList && mp.classList.contains('ad-showing'));
                    if (isAd) {
                        wasAd = true;
                        document.querySelectorAll(
                            '.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button,' +
                            '.ytp-ad-skip-button-container button, button[aria-label*=\"Skip\"]'
                        ).forEach(function(b) { b.click(); });
                        document.querySelectorAll('.ytp-ad-overlay-close-button').forEach(function(o) { o.click(); });
                        video.muted = true;
                    } else if (wasAd) {
                        wasAd = false;
                        if (window.__kasetTargetVolume === undefined || window.__kasetTargetVolume > 0) {
                            video.muted = false;
                        }
                    }
                } catch (e) {}
            }
            setInterval(killAd, 250);
            if (window.MutationObserver) {
                new MutationObserver(killAd).observe(document.documentElement, {
                    attributes: true, subtree: true, attributeFilter: ['class']
                });
            }
        })();
        """
    }()
}
