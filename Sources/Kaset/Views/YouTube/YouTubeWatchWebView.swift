import os
import SwiftUI
import WebKit

// MARK: - ScrollPassthroughWebView

/// WKWebView that forwards scroll-wheel events to the enclosing SwiftUI
/// ScrollView. The extracted watch page is `overflow: hidden`, so the page
/// never scrolls; without this, a hovered WebView swallows wheel events and
/// dead-zones the surrounding scroll wherever the video sits. Forwarding to the
/// next responder lets the watch page keep scrolling with the cursor over the
/// video. In the floating window there is no scrollable ancestor, so it's a
/// harmless no-op.
final class ScrollPassthroughWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        self.nextResponder?.scrollWheel(with: event)
    }
}

// MARK: - YouTubeWatchWebView

/// Manages the single WebView used for regular YouTube video playback.
///
/// Parallel to `SingletonPlayerWebView` (music) but tuned to youtube.com
/// watch pages: its own observer script (`#movie_player` instead of
/// `ytmusic-*` selectors), its own message handler name (`youtubePlayer`),
/// and a chrome-hiding extraction that leaves only the video surface
/// visible so the page can dock into native Kaset views.
///
/// Exactly one of music/video produces audio at a time — `PlaybackArbiter`
/// enforces the handoff.
@MainActor
final class YouTubeWatchWebView {
    static let shared = YouTubeWatchWebView()

    private(set) var webView: WKWebView?
    weak var webKitManager: WebKitManager?
    private weak var currentContainer: NSView?
    private var usesCookieFreeDataStore: Bool?
    var currentVideoId: String?
    var coordinator: Coordinator?
    let logger = DiagnosticsLogger.player

    /// Seek position (seconds) to apply once the next page finishes loading.
    /// Used to resume a video at its prior position after a forced reload (e.g.
    /// an account/session-identity switch), since the `<video>` element does not
    /// exist until the new document loads. Cleared on apply.
    var pendingSeek: Double?

    /// Monotonic counter for `load(videoId:)` calls. The pre-navigation pause is
    /// async, so a newer load can be requested before an older one's callback
    /// issues `webView.load`. The callback captures the generation and bails if
    /// superseded, so a stale reload can't navigate over a newer selection.
    private var loadGeneration = 0

    /// Monotonic counter for actual document navigations, baked into each page
    /// via the bootstrap script (`window.__kasetDocGeneration`) and echoed back
    /// in every STATE_UPDATE/VIDEO_ENDED. After a new video is requested the old
    /// page's observer briefly keeps posting for the prior video; those messages
    /// carry the old generation and are dropped (see the Coordinator gate).
    ///
    /// Distinct from `loadGeneration`, which `cancelPendingLoad()` bumps on
    /// pause without navigating — reusing it would wrongly drop the still-live
    /// (merely paused) document's updates. This only advances on a real load.
    private(set) var documentGeneration = 0

    private init() {}

    /// Get or create the watch WebView.
    func getWebView(
        webKitManager: WebKitManager,
        playerService: YouTubePlayerService,
        usesCookieFreeDataStore: Bool = false
    ) -> WKWebView {
        if let existing = webView, self.usesCookieFreeDataStore == usesCookieFreeDataStore {
            return existing
        }
        let previousContainer = self.currentContainer
        if self.webView != nil {
            self.logger.info("Recreating YouTube watch WebView for auth data-store boundary")
            self.tearDown()
        }

        self.logger.info("Creating YouTube watch WebView")
        self.usesCookieFreeDataStore = usesCookieFreeDataStore

        self.coordinator = Coordinator(playerService: playerService)

        let configuration = webKitManager.createWebViewConfiguration(
            websiteDataStore: usesCookieFreeDataStore ? .nonPersistent() : nil,
            // Never network-block ads on the YouTube player: it stalls the
            // player on the killed ad request and blanks the video. The DOM
            // skip script (installed below when ad blocking is on) handles
            // client-side ads without breaking playback.
            applyAdBlock: false
        )
        configuration.userContentController.add(self.coordinator!, name: "youtubePlayer")
        self.installUserScripts(
            on: configuration.userContentController,
            documentGeneration: self.documentGeneration,
            targetVolume: playerService.volume
        )

        let newWebView = ScrollPassthroughWebView(frame: .zero, configuration: configuration)
        newWebView.navigationDelegate = self.coordinator
        newWebView.customUserAgent = WebKitManager.userAgent
        self.webKitManager = webKitManager
        webKitManager.registerExtensionHostWebView(newWebView, role: .youtubeWatch)

        // Kill the white flash between page navigations.
        newWebView.underPageBackgroundColor = .black

        #if DEBUG
            newWebView.isInspectable = true
        #endif

        self.webView = newWebView
        if let previousContainer {
            self.ensureInHierarchy(container: previousContainer)
        }
        return newWebView
    }

    /// Ensures the WebView fills the given container (reparenting if needed).
    func ensureInHierarchy(container: NSView) {
        guard let webView else { return }
        self.currentContainer = container
        self.webKitManager?.extensionHostWebViewDidBecomeActive(webView)
        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        container.addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
    }

    /// Loads a watch page for the given video, skipping if it is already current.
    func loadVideo(videoId: String) {
        guard videoId != self.currentVideoId else {
            self.logger.debug("YouTube video \(videoId) already loaded, skipping")
            return
        }
        // A normal (non-reload) load starts a fresh video: drop any pending
        // resume-seek left over from an interrupted identity-switch reload, so it
        // cannot be injected into a different video's document.
        self.pendingSeek = nil
        self.load(videoId: videoId)
    }

    /// Forces a full reload of the given video even when it is already current,
    /// optionally resuming at `resumeAt` seconds once the new page loads.
    ///
    /// Used after an account/session-identity switch: the page identity lives in
    /// the served document, so the in-flight watch page must be re-fetched under
    /// the new session for subsequent watch-history pings to attribute correctly.
    func reloadVideo(videoId: String, resumeAt seconds: Double? = nil) {
        self.logger.info("Force-reloading YouTube video under new session identity: \(videoId)")
        self.pendingSeek = seconds
        self.load(videoId: videoId)
    }

    func cancelPendingLoad() {
        self.loadGeneration += 1
        self.webView?.stopLoading()
    }

    private func load(videoId: String) {
        guard let webView else {
            self.logger.error("YouTube watch load called but webView is nil")
            return
        }

        self.logger.info("Loading YouTube video: \(videoId) (was: \(self.currentVideoId ?? "none"))")
        self.currentVideoId = videoId

        self.loadGeneration += 1
        let myLoadGeneration = self.loadGeneration
        self.documentGeneration += 1

        let isShort = self.coordinator?.playerService.currentVideo?.videoId == videoId
            && self.coordinator?.playerService.currentVideo?.isShort == true
        let targetVolume = self.coordinator?.playerService.volume ?? 1.0
        self.installUserScripts(
            on: webView.configuration.userContentController,
            documentGeneration: self.documentGeneration,
            targetVolume: targetVolume,
            pendingSeek: self.pendingSeek,
            isShort: isShort
        )

        guard let url = URL(string: "https://www.youtube.com/watch?v=\(videoId)") else { return }
        webView.evaluateJavaScript("document.querySelector('video')?.pause()") { [weak self] _, _ in
            guard let self, let webView = self.webView else { return }
            // Bail if a newer load was requested while the pause callback was
            // pending — otherwise this stale URL would navigate over the newer
            // selection and the observer would follow the wrong video.
            guard myLoadGeneration == self.loadGeneration,
                  self.currentVideoId == videoId
            else {
                self.logger.debug("YouTube load superseded before navigation; skipping stale \(url.absoluteString)")
                return
            }
            webView.evaluateJavaScript("window.__kasetTargetVolume = \(targetVolume);", completionHandler: nil)
            webView.load(URLRequest(url: url))
        }
    }

    /// Stops playback and blanks the page (called when video playback is closed).
    func tearDown() {
        guard let webView else { return }
        self.logger.info("Tearing down YouTube watch WebView")
        self.loadGeneration += 1
        self.documentGeneration += 1
        self.currentVideoId = nil
        webView.evaluateJavaScript("window.__kasetStopYTExtraction?.(); document.querySelector('video')?.pause()") { _, _ in }
        webView.loadHTMLString("", baseURL: nil)
        webView.removeFromSuperview()
        self.webKitManager?.extensionHostWebViewDidDeactivate(role: .youtubeWatch)
        self.webView = nil
        self.coordinator = nil
        self.currentContainer = nil
        self.usesCookieFreeDataStore = nil
    }

    // MARK: - User Scripts

    private func installUserScripts(
        on contentController: WKUserContentController,
        documentGeneration: Int,
        targetVolume: Double,
        pendingSeek: Double? = nil,
        isShort: Bool = false
    ) {
        contentController.removeAllUserScripts()

        let sbSettings = SettingsManager.shared
        let bootstrap = WKUserScript(
            source: Self.pageBootstrapScript(
                documentGeneration: documentGeneration,
                targetVolume: targetVolume,
                pendingSeek: pendingSeek,
                sponsorBlockEnabled: sbSettings.sponsorBlockEnabled,
                sponsorBlockCategories: sbSettings.sponsorBlockCategories
            ),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        contentController.addUserScript(bootstrap)

        // Black from first paint — no YouTube layout flash before extraction.
        let blackout = WKUserScript(
            source: Self.blackoutScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        contentController.addUserScript(blackout)

        let observer = WKUserScript(
            source: Self.observerScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        contentController.addUserScript(observer)

        let extraction = WKUserScript(
            source: Self.extractionScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        contentController.addUserScript(extraction)

        let sponsorBlock = WKUserScript(
            source: Self.sponsorBlockScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        contentController.addUserScript(sponsorBlock)

        // Ad-block: json-prune + skip. MUST run at document-start so
        // JSON.parse is overridden before YouTube's JS loads ad data.
        // Skipped for Shorts: they carry no ads, and the JSON.parse override
        // adds needless overhead to the (already slow) watch-page load.
        if !isShort, SettingsManager.shared.adBlockEnabled {
            let adBlock = WKUserScript(
                source: AdBlockService.adBlockScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            contentController.addUserScript(adBlock)
        }
    }

    /// Document-start state handed to each new watch page.
    ///
    /// `pendingSeek`, when present, is a resume position (seconds) applied by the
    /// observer once the `<video>` element exists and is seekable (see
    /// `applyPendingSeek` in the observer script). Injected at document start so
    /// it is in place before the player boots, and naturally scoped to this one
    /// navigation.
    nonisolated static func pageBootstrapScript(
        documentGeneration: Int = 0,
        targetVolume: Double,
        pendingSeek: Double? = nil,
        sponsorBlockEnabled: Bool,
        sponsorBlockCategories: [String]
    ) -> String {
        let clamped = targetVolume.isFinite ? min(max(targetVolume, 0), 1) : 1.0
        // Stamp this document's generation so the bridge can drop late messages
        // from a superseded page (see Coordinator's generation gate).
        var script = "window.__kasetDocGeneration = \(documentGeneration);"
        script += " window.__kasetTargetVolume = \(clamped);"
        if let pendingSeek, pendingSeek.isFinite, pendingSeek >= 0 {
            script += " window.__kasetPendingSeek = \(pendingSeek);"
        }

        // SponsorBlock config — injected so the SB user script can read it
        let catsJSON = "[" + sponsorBlockCategories.map { "\"\($0)\"" }.joined(separator: ",") + "]"

        // ponytail: inject localized labels so the toast speaks the user's language.
        // JSON-encode each value to prevent JS injection through localized strings.
        func jsStr(_ value: String) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
                  let json = String(data: data, encoding: .utf8)
            else { return "\"\"" }
            return json
        }

        let labelSkipped = String(localized: "Skipped")
        let labelUndo = String(localized: "Undo")
        let catSponsor = String(localized: "Sponsor")
        let catSelfpromo = String(localized: "Self-promotion")
        let catInteraction = String(localized: "Interaction Reminder")
        let catIntro = String(localized: "Intro")
        let catOutro = String(localized: "Outro")
        let catPreview = String(localized: "Preview / Recap")
        let catMusicOfftopic = String(localized: "Non-Music")
        let catFiller = String(localized: "Filler")

        script += """
         window.__kasetSponsorBlock = {enabled:\(sponsorBlockEnabled),categories:\(catsJSON),\
        labels:{skipped:\(jsStr(labelSkipped)),undo:\(jsStr(labelUndo)),\
        sponsor:\(jsStr(catSponsor)),selfpromo:\(jsStr(catSelfpromo)),\
        interaction:\(jsStr(catInteraction)),intro:\(jsStr(catIntro)),\
        outro:\(jsStr(catOutro)),preview:\(jsStr(catPreview)),\
        music_offtopic:\(jsStr(catMusicOfftopic)),filler:\(jsStr(catFiller))}};

        """

        return script
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let playerService: YouTubePlayerService

        init(playerService: YouTubePlayerService) {
            self.playerService = playerService
        }

        func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String
            else { return }

            // Drop playback messages from a superseded document: after a new
            // video is requested the old page's observer briefly keeps posting
            // for the prior video, which would corrupt the new track's state.
            // The generation is baked into each page and only advances on a real
            // navigation, so a still-live (merely paused) page is never dropped.
            if type == "STATE_UPDATE" || type == "VIDEO_ENDED",
               let generation = body["generation"] as? Int,
               generation != YouTubeWatchWebView.shared.documentGeneration
            {
                return
            }

            switch type {
            case "STATE_UPDATE":
                let update = YouTubePlayerService.PlaybackUpdate(
                    isPlaying: body["isPlaying"] as? Bool ?? false,
                    progress: body["progress"] as? Double ?? 0,
                    duration: body["duration"] as? Double ?? 0,
                    videoId: (body["videoId"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                    title: body["title"] as? String,
                    isAd: body["isAd"] as? Bool ?? false,
                    isAdSkippable: body["isAdSkippable"] as? Bool ?? false
                )
                Task { @MainActor in
                    self.playerService.updatePlaybackState(update)
                }
            case "VIDEO_ENDED":
                let videoId = body["videoId"] as? String
                Task { @MainActor in
                    self.playerService.handleVideoEnded(videoId: videoId)
                }
            case "SPONSOR_SEGMENTS":
                guard let videoId = body["videoId"] as? String else { return }
                let segmentDictionaries = body["segments"] as? [[String: Any]] ?? []
                let segments: [SponsorSegment] = segmentDictionaries.compactMap { dict in
                    guard let start = dict["start"] as? Double,
                          let end = dict["end"] as? Double,
                          let category = dict["category"] as? String
                    else { return nil }
                    return SponsorSegment(start: start, end: end, category: category)
                }
                Task { @MainActor in
                    self.playerService.setSponsorSegments(segments, videoId: videoId)
                }
            case "SPONSOR_SKIPPED":
                guard let start = body["start"] as? Double,
                      let end = body["end"] as? Double,
                      let category = body["category"] as? String,
                      let videoId = body["videoId"] as? String
                else { return }
                Task { @MainActor in
                    self.playerService.handleSponsorBlockSkip(
                        start: start,
                        end: end,
                        category: category,
                        videoId: videoId
                    )
                }
            default:
                return
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.targetFrame?.isMainFrame == true else {
                decisionHandler(.allow)
                return
            }

            YouTubeWatchWebView.shared.webKitManager?.extensionHostWebViewWillNavigate(
                webView,
                to: navigationAction.request.url
            )
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
            YouTubeWatchWebView.shared.webKitManager?.extensionHostWebViewDidStartNavigation(webView)
        }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            YouTubeWatchWebView.shared.webKitManager?.extensionHostWebViewDidFinishNavigation(webView)
            DiagnosticsLogger.player.info(
                "YouTube watch WebView finished loading: \(webView.url?.absoluteString ?? "nil")"
            )

            // If YouTube served something other than a watch page — Google's
            // "/sorry/" unusual-traffic CAPTCHA or the EU consent interstitial —
            // our chrome-hiding extraction would leave it invisible and the video
            // stuck "loading". Reveal the page so the user can actually solve it.
            if let url = webView.url?.absoluteString,
               url.contains("google.com/sorry") || url.contains("/sorry/")
               || url.contains("consent.youtube") || url.contains("consent.google")
            {
                webView.evaluateJavaScript(
                    """
                    (function() {
                        try { if (window.__kasetStopYTExtraction) { window.__kasetStopYTExtraction(); } } catch (e) {}
                        ['kaset-yt-blackout', 'kaset-yt-video-style'].forEach(function(id) {
                            var el = document.getElementById(id);
                            if (el) { el.remove(); }
                        });
                        var s = document.createElement('style');
                        s.textContent = 'html, body, * { visibility: visible !important; }';
                        document.documentElement.appendChild(s);
                    })();
                    """,
                    completionHandler: nil
                )
                self.playerService.clearPlaybackLoadingForInterstitial()
            }

            // The resume-seek for an identity-switch reload is applied by the
            // observer's applyPendingSeek (gated on the <video> existing and being
            // seekable), not here: at didFinish the element often does not exist
            // yet, so a one-shot seek would be lost. Clear the Swift-side copy now
            // that the per-load bootstrap has carried the value into the page.
            YouTubeWatchWebView.shared.pendingSeek = nil

            let savedVolume = self.playerService.volume
            webView.evaluateJavaScript(
                """
                (function() {
                    window.__kasetTargetVolume = \(savedVolume);
                    const video = document.querySelector('video');
                    if (video) { video.volume = \(savedVolume); }
                    if (window.__kasetExtractVideo) { window.__kasetExtractVideo(); }
                })();
                """,
                completionHandler: nil
            )
        }

        func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError _: Error) {
            YouTubeWatchWebView.shared.webKitManager?.extensionHostWebViewDidFailNavigation(webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError _: Error) {
            YouTubeWatchWebView.shared.webKitManager?.extensionHostWebViewDidFailNavigation(webView)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            DiagnosticsLogger.player.error("YouTube watch WebView content process terminated, recovering")
            let videoId = YouTubeWatchWebView.shared.currentVideoId
            webView.reload()
            if let videoId {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    YouTubeWatchWebView.shared.currentVideoId = nil
                    YouTubeWatchWebView.shared.loadVideo(videoId: videoId)
                }
            }
        }
    }
}
