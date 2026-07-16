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

    /// JS injected into YouTube watch pages at document-start (only when ad
    /// blocking is enabled — same gate as the `contentRulesJSON` network list).
    ///
    /// DOM-side ad skip only. Stripping ad scheduling from the player response
    /// (`adPlacements` etc. via an accessor trap or fetch rewrite) was measured
    /// to break playback outright: the media source is never created
    /// (`readyState`/`networkState`/`currentSrc` all empty), YouTube's
    /// anti-adblock detecting the tampering. So we never touch the player JSON;
    /// we only fast-skip whatever the player itself exposes as a discrete ad.
    static let adBlockScript: String = {
        """
        (function() {
            'use strict';

            // ── Ad skip (safe) ───────────────────────────────
            // Only clicks YouTube's own "Skip" button / closes overlay ads —
            // exactly what a user would do, so it can never corrupt the player.
            // Seeking the ad clip or forcing playbackRate was tried and broke
            // the ad→content handoff (the video played ~0.5s then went black).
            function killAd() {
                try {
                    var player = document.getElementById('movie_player');
                    if (!player || !player.classList.contains('ad-showing')) return;
                    document.querySelectorAll(
                        '.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button,' +
                        '.ytp-ad-skip-button-container button, button[aria-label*=\"Skip\"]'
                    ).forEach(function(b) { b.click(); });
                    document.querySelectorAll('.ytp-ad-overlay-close-button').forEach(function(o) { o.click(); });
                } catch(e) {}
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
