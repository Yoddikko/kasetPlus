// swiftlint:disable file_length
import Foundation
import os
import YouTubeAskCore

// MARK: - YouTubeClient

/// Client for making authenticated requests to regular YouTube's internal
/// InnerTube API (`www.youtube.com/youtubei/v1`, `WEB` client).
///
/// Parallel to `YTMusicClient` by design: the request scaffolding is
/// intentionally duplicated rather than shared so the proven music path
/// stays untouched. The critical difference is the origin — SAPISIDHASH
/// and the `Origin`/`Referer`/`X-Origin` headers must all use
/// `https://www.youtube.com`, not the music origin.
///
/// Unlike the music client, no API key is attached: the `key=` query
/// parameter is no longer required by InnerTube (confirmed June 2026).
@MainActor
final class YouTubeClient: YouTubeClientProtocol { // swiftlint:disable:this type_body_length
    private let authService: AuthService
    private let webKitManager: WebKitManager
    private let session: URLSession
    private let cache: APICache
    let askTransport: YouTubeAskTransport
    let askMessageIDGenerator: YouTubeAskMessageIDGenerator
    private let askRequestProfile: YouTubeAskRequestProfile?
    private let logger = DiagnosticsLogger.api

    /// Provider for the current brand account ID (mirrors `YTMusicClient`).
    var brandIdProvider: (() -> String?)?

    /// Provider for the current account identity used only to scope cache keys.
    ///
    /// `brandIdProvider` is nil for primary accounts, so personalized YouTube
    /// caches also need the selected account identity to avoid reusing primary
    /// account responses across sign-in/account changes.
    var accountCacheIdentityProvider: (() -> String?)?

    /// Provider for a verified primary-account scope eligible for Ask Gemini.
    /// `nil` covers signed-out, guest, unresolved, and brand-account states.
    var askAccountBindingProvider: (() -> YouTubeAskAccountBinding?)?

    /// YouTube API base URL.
    private static let baseURL = "https://www.youtube.com/youtubei/v1"

    /// Request origin — also the SAPISIDHASH input origin.
    static let origin = "https://www.youtube.com"

    /// Client version for WEB (live value observed June 2026; InnerTube
    /// accepts moderately stale versions).
    private static let clientVersion = YouTubeAskRequestProfile.productionClientVersion

    /// Cache-key prefix so YouTube entries never collide with music
    /// invalidation patterns ("browse:", "next:", …).
    private static let cachePrefix = "yt:"

    private var homeContinuation: String?
    /// Advances whenever a new initial Home request starts, invalidating any
    /// older initial-page or continuation cursor publication.
    private var homePaginationEpoch: UInt64 = 0
    private var searchContinuation: String?
    private var askSessionGeneration: UInt64 = 0
    private var consumedAskBootstraps: Set<UUID> = []
    private var consumedAskRevisions: Set<AskRevisionKey> = []

    var hasMoreHomeFeed: Bool {
        self.homeContinuation != nil
    }

    func resetSessionStateForAccountSwitch() {
        self.homePaginationEpoch &+= 1
        self.homeContinuation = nil
        self.searchContinuation = nil
        self.askSessionGeneration &+= 1
        self.consumedAskBootstraps = []
        self.consumedAskRevisions = []
    }

    init(
        authService: AuthService,
        webKitManager: WebKitManager = .shared,
        session: URLSession? = nil,
        askMessageIDGenerator: YouTubeAskMessageIDGenerator? = nil,
        askFeatureEnabled: Bool = false,
        cache: APICache = .shared
    ) {
        self.authService = authService
        self.webKitManager = webKitManager

        let resolvedSession: URLSession = if let session {
            session
        } else {
            URLSession(configuration: APISessionConfiguration.make())
        }
        self.session = resolvedSession
        self.cache = cache
        self.askTransport = YouTubeAskTransport(configuration: resolvedSession.configuration)
        self.askMessageIDGenerator = askMessageIDGenerator ?? YouTubeAskMessageIDGenerator()
        // Ask remains an explicit construction-time capability. The production
        // app selects the fixed WEB profile; isolated clients and tests default off.
        self.askRequestProfile = askFeatureEnabled ? .fixedProduction : nil
    }

    // MARK: - Home Feed

    func getHomeFeed() async throws -> YouTubeFeed {
        self.logger.info("Fetching YouTube home feed")
        self.homePaginationEpoch &+= 1
        let paginationEpoch = self.homePaginationEpoch
        self.homeContinuation = nil

        let data = try await self.request(
            "browse",
            body: ["browseId": "FEwhat_to_watch"],
            ttl: APICache.TTL.home
        )
        let feed = YouTubeFeedParser.parse(data)
        if paginationEpoch == self.homePaginationEpoch {
            self.homeContinuation = feed.continuation
        }
        self.logger.info("YouTube home feed loaded: \(feed.videos.count) videos, hasMore: \(feed.continuation != nil)")
        return feed
    }

    func getHomeBundle(forceRefresh: Bool) async throws -> YouTubeHomeBundle {
        self.logger.info("Fetching YouTube home bundle (feed + chips + shelves)")
        self.homePaginationEpoch &+= 1
        let paginationEpoch = self.homePaginationEpoch
        self.homeContinuation = nil

        let bundle = try await self.homeBundle(forceRefresh: forceRefresh)
        // The detached parse is not cancelled when the Home view model is
        // discarded (account switch). Don't mutate shared client state after
        // cancellation — the providers may already have moved to the new account.
        try Task.checkCancellation()
        if paginationEpoch == self.homePaginationEpoch {
            self.homeContinuation = bundle.feed.continuation
        }
        self.logger.info(
            "YouTube home bundle: \(bundle.feed.videos.count) videos, \(bundle.chips.count) chips, \(bundle.shelves.count) shelves"
        )
        return bundle
    }

    /// Loads + parses the shared `FEwhat_to_watch` bundle. The 2 MB deserialize
    /// + walk always runs OFF the main actor (`parseHomeBundle` on a detached
    /// task), which also validates the payload — it throws on non-JSON — so the
    /// raw bytes are cached only after a successful parse, with no main-actor
    /// deserialize and no redundant second parse. Home and Shorts share this so
    /// the response and its cache entry are reused.
    private func homeBundle(forceRefresh: Bool) async throws -> YouTubeHomeBundle {
        let homeBody: [String: Any] = ["browseId": "FEwhat_to_watch"]
        // Capture cache generation and logical request order before auth awaits.
        // The scoped key is resolved afterward from the actual auth result.
        let cacheGeneration = self.cache.generation
        let cacheWriteTicket = self.cache.prepareWrite(cacheGeneration: cacheGeneration)
        defer {
            if let cacheWriteTicket {
                self.cache.finishWrite(cacheWriteTicket)
            }
        }
        let homeAuth = try await self.buildRequestHeaders(authPolicy: .optional)
        let cacheKey = self.homeDataCacheKey(body: homeBody, authenticated: homeAuth.authenticated)

        if !forceRefresh, let cacheKey, let cached = self.cachedHomeData(key: cacheKey) {
            let bundle = try await Self.parseHomeBundle(from: cached)
            try self.validateAuthIdentity(
                authenticated: homeAuth.authenticated,
                generation: homeAuth.authIdentityGeneration
            )
            return bundle
        }

        let cacheWrite = cacheKey.flatMap { key in
            cacheWriteTicket.flatMap { self.cache.beginWrite(for: key, ticket: $0) }
        }

        let data = try await self.requestData("browse", body: homeBody, requestAuth: homeAuth)
        // Parse off-main; this throws on a non-JSON 200, so we never cache bytes
        // that don't parse.
        let bundle = try await Self.parseHomeBundle(from: data)
        try self.validateAuthIdentity(
            authenticated: homeAuth.authenticated,
            generation: homeAuth.authIdentityGeneration
        )
        try Task.checkCancellation()

        // Cache only if no account switch / sign-out happened during the fetch
        // (key AND generation unchanged).
        if let cacheKey,
           cacheKey == self.homeDataCacheKey(body: homeBody, authenticated: homeAuth.authenticated),
           let cacheWrite
        {
            self.cache.setDataIfCurrent(
                key: cacheKey,
                data: data,
                ttl: APICache.TTL.home,
                reservation: cacheWrite
            )
        }
        return bundle
    }

    /// Off-actor parse of the home bundle, kept on a detached task so the 2 MB
    /// deserialize + walk does not block the main actor.
    private static func parseHomeBundle(from data: Data) async throws -> YouTubeHomeBundle {
        try await Task.detached(priority: .userInitiated) {
            try YouTubeFeedParser.parseHomeBundle(from: data)
        }.value
    }

    func getHomeFeedContinuation() async throws -> YouTubeFeed? {
        guard let continuation = self.homeContinuation else {
            return nil
        }
        let paginationEpoch = self.homePaginationEpoch

        let data = try await self.request("browse", body: ["continuation": continuation])
        let feed = YouTubeFeedParser.parseContinuation(data)
        guard paginationEpoch == self.homePaginationEpoch else {
            self.logger.info("Discarding stale YouTube home continuation after feed reload")
            return nil
        }
        self.homeContinuation = feed.continuation
        self.logger.info("YouTube home continuation: \(feed.videos.count) videos")
        return feed
    }

    func getHomeChips() async throws -> [YouTubeHomeChip] {
        // Chips ride along in the home feed response; the shared TTL means this
        // is a cache hit right after the home grid loads (cf. getShorts()).
        let data = try await self.request(
            "browse",
            body: ["browseId": "FEwhat_to_watch"],
            ttl: APICache.TTL.home
        )
        let chips = YouTubeFeedParser.parseChips(data)
        self.logger.info("YouTube home chips: \(chips.count) topics")
        return chips
    }

    func getHomeShelves() async throws -> [YouTubeHomeSection] {
        // Same cached home response; extracts the response's own titled shelves.
        let data = try await self.request(
            "browse",
            body: ["browseId": "FEwhat_to_watch"],
            ttl: APICache.TTL.home
        )
        let shelves = YouTubeFeedParser.parseHomeShelves(data)
        self.logger.info("YouTube home shelves: \(shelves.count)")
        return shelves
    }

    func getHomeTopicFeed(continuation: String, forceRefresh: Bool) async throws -> YouTubeFeed {
        // A chip browse uses the same `browse` continuation wire shape as
        // pagination, but returns a fresh topic-filtered grid (reload
        // semantics) with its own trailing continuation token. Cached (keyed on
        // the continuation token via the request body) so returning to Home
        // shows its rails immediately instead of re-fetching every topic over
        // the network — which made the rows "snap" in well after the grid.
        let data = try await self.request(
            "browse",
            body: ["continuation": continuation],
            ttl: APICache.TTL.home,
            bypassCache: forceRefresh
        )
        return YouTubeFeedParser.parseContinuation(data)
    }

    // MARK: - Search

    func search(query: String, params: String?) async throws -> YouTubeSearchResponse {
        self.logger.info("Searching YouTube")

        var body: [String: Any] = ["query": query]
        if let params {
            body["params"] = params
        }

        let data = try await self.request("search", body: body, ttl: APICache.TTL.search)
        var response = YouTubeSearchParser.parse(data)
        self.searchContinuation = response.continuation
        response.continuation = self.searchContinuation
        self.logger.info(
            "YouTube search: \(response.videos.count) videos, \(response.channels.count) channels, \(response.playlists.count) playlists"
        )
        return response
    }

    func getSearchContinuation() async throws -> YouTubeSearchResponse? {
        guard let continuation = self.searchContinuation else {
            return nil
        }

        let response = try await self.getSearchContinuation(continuation: continuation)
        if self.searchContinuation == continuation {
            self.searchContinuation = response?.continuation
        }
        return response
    }

    func getSearchContinuation(continuation: String) async throws -> YouTubeSearchResponse? {
        let data = try await self.request("search", body: ["continuation": continuation])
        return YouTubeSearchParser.parseContinuation(data)
    }

    // MARK: - Watch

    func getWatchNext(videoId: String, playlistId: String?) async throws -> WatchNextData {
        self.logger.info("Fetching watch-next data")

        var body: [String: Any] = ["videoId": videoId]
        // A Mix (radio) playlist turns the watch-next into the endless mix queue.
        if let playlistId {
            body["playlistId"] = playlistId
        }
        let data = try await self.request("next", body: body)
        return WatchNextParser.parse(data)
    }

    /// Fetches the `player` playability status for a members-only gate. Signed-in
    /// (auth `.required`) because membership access is per-account, and uncached
    /// so a freshly-joined member sees the video unlock on the next open.
    func getPlayability(videoId: String) async throws -> YouTubePlayability {
        self.logger.info("Fetching playability status")

        let data = try await self.request(
            "player",
            body: ["videoId": videoId],
            authPolicy: .required
        )
        return WatchNextParser.playability(data)
    }

    func getWatchPage(videoId: String, playlistId: String? = nil) async throws -> YouTubeWatchPage {
        self.logger.info("Fetching YouTube watch page")

        let accountBinding = self.currentAskAccountBinding()
        let askGeneration = self.askSessionGeneration
        let requestAuth = try await self.buildRequestHeaders(authPolicy: .optional)
        var body: [String: Any] = ["videoId": videoId]
        // A Mix (radio) playlist turns the watch-next into the endless mix queue.
        if let playlistId {
            body["playlistId"] = playlistId
        }
        let data = try await self.requestData(
            "next",
            body: body,
            requestAuth: requestAuth
        )
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YTMusicError.parseError(message: "Watch response is not a JSON object")
        }

        let watchData = WatchNextParser.parse(json)
        guard requestAuth.authenticated,
              let authenticationGeneration = requestAuth.authIdentityGeneration,
              let accountBinding,
              askGeneration == self.askSessionGeneration,
              accountBinding == self.currentAskAccountBinding()
        else {
            return YouTubeWatchPage(data: watchData, askBootstrap: nil)
        }

        let parsedBootstrap: YouTubeAskParsedBootstrap?
        do {
            parsedBootstrap = try await Task.detached(priority: .userInitiated) {
                let envelope = try YouTubeAskWireDecoder.decode(data)
                return try YouTubeAskParser.parseBootstrap(from: envelope)
            }.value
            try self.validateAskIdentity(
                authenticationGeneration: authenticationGeneration,
                accountBinding: accountBinding,
                clientGeneration: askGeneration
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            self.logger.warning("Ask bootstrap rejected by strict parser")
            return YouTubeWatchPage(data: watchData, askBootstrap: nil)
        }

        guard let parsedBootstrap else {
            return YouTubeWatchPage(data: watchData, askBootstrap: nil)
        }
        let bootstrap = YouTubeAskBootstrap.production(
            videoID: videoId,
            parsed: parsedBootstrap,
            authenticationGeneration: authenticationGeneration,
            accountBinding: accountBinding,
            clientGeneration: askGeneration
        )
        return YouTubeWatchPage(data: watchData, askBootstrap: bootstrap)
    }

    func getComments(continuation: String) async throws -> YouTubeCommentsPage {
        self.logger.info("Fetching YouTube comments page")

        let data = try await self.request("next", body: ["continuation": continuation])
        return YouTubeCommentsParser.parse(data)
    }

    /// Fetches one page of a live stream's chat. Poll again with the returned
    /// continuation after waiting its `timeoutMs`.
    func getLiveChat(continuation: String) async throws -> YouTubeLiveChatPage {
        let data = try await self.request("live_chat/get_live_chat", body: ["continuation": continuation])
        return LiveChatParser.parse(data)
    }

    func sendLiveChatMessage(text: String, params: String) async throws {
        self.logger.info("Sending live chat message")

        let body: [String: Any] = [
            "richMessage": ["textSegments": [["text": text]]],
            "params": params,
        ]
        _ = try await self.request("live_chat/send_message", body: body, retry: false)
    }

    func postComment(text: String, createCommentParams: String) async throws {
        self.logger.info("Posting YouTube comment")

        let body: [String: Any] = [
            "commentText": text,
            "createCommentParams": createCommentParams,
        ]
        _ = try await self.request("comment/create_comment", body: body, retry: false)
    }

    func performCommentAction(_ action: String) async throws {
        self.logger.info("Performing comment action")

        let body: [String: Any] = ["actions": [action]]
        _ = try await self.request("comment/perform_comment_action", body: body, retry: false)
    }

    // MARK: - Browse

    func getChannel(channelId: String) async throws -> YouTubeChannelDetail {
        self.logger.info("Fetching YouTube channel page")

        let data = try await self.request(
            "browse",
            body: ["browseId": channelId],
            ttl: APICache.TTL.artist
        )
        guard let detail = ChannelPageParser.parse(data, channelId: channelId) else {
            throw YTMusicError.parseError(message: "Could not parse channel page")
        }
        return detail
    }

    func getChannelTab(channelId: String, tab: YouTubeChannelTab) async throws -> YouTubeChannelTabContent {
        self.logger.info("Fetching YouTube channel tab: \(tab.rawValue)")

        var body: [String: Any] = ["browseId": channelId]
        if let params = tab.browseParams {
            body["params"] = params
        }
        let data = try await self.request("browse", body: body, ttl: APICache.TTL.artist)

        if tab.showsPlaylists {
            // collectPlaylists doesn't surface a continuation; channels rarely
            // have enough playlists to need one.
            return .playlists(YouTubeFeedParser.collectPlaylists(data), continuation: nil)
        }

        // Collect BOTH videos and shorts (the Shorts tab uses shortsLockup items)
        // so the Shorts tab isn't dropped, and capture the continuation token.
        var videos: [YouTubeVideo] = []
        var shorts: [YouTubeVideo] = []
        var continuation: String?
        if let contents = data["contents"] {
            YouTubeFeedParser.collect(in: contents, videos: &videos, shorts: &shorts, continuation: &continuation)
        }
        return .videos(YouTubeFeedParser.deduplicate(videos + shorts), continuation: continuation)
    }

    func getChannelTabContinuation(token: String) async throws -> ([YouTubeVideo], continuation: String?) {
        let data = try await self.request("browse", body: ["continuation": token])
        let feed = YouTubeFeedParser.parseContinuation(data)
        return (YouTubeFeedParser.deduplicate(feed.videos + feed.shorts), feed.continuation)
    }

    func getPlaylist(playlistId: String) async throws -> YouTubePlaylistDetail {
        self.logger.info("Fetching YouTube playlist page")

        let browseId = playlistId.hasPrefix("VL") ? playlistId : "VL\(playlistId)"
        let data = try await self.request(
            "browse",
            body: ["browseId": browseId],
            ttl: APICache.TTL.playlist
        )
        let id = playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId
        return YouTubePlaylistPageParser.parse(data, playlistId: id)
    }

    func getDestinationFeed(_ destination: YouTubeDestination) async throws -> YouTubeFeed {
        self.logger.info("Fetching YouTube destination feed: \(destination.rawValue)")

        let data = try await self.request(
            "browse",
            body: ["browseId": destination.browseId],
            ttl: APICache.TTL.home
        )
        return YouTubeFeedParser.parse(data)
    }

    func getFeedContinuation(continuation: String) async throws -> YouTubeFeed {
        let data = try await self.request("browse", body: ["continuation": continuation])
        return YouTubeFeedParser.parseContinuation(data)
    }

    func getPrivateFeedContinuation(continuation: String) async throws -> YouTubeFeed {
        let data = try await self.request("browse", body: ["continuation": continuation], authPolicy: .required)
        return YouTubeFeedParser.parseContinuation(data)
    }

    func getShorts() async throws -> [YouTubeVideo] {
        self.logger.info("Fetching YouTube Shorts")

        // Aggregate every source instead of short-circuiting on Home's handful
        // of shorts — the surface needs a deep feed to scroll, not 5 items.
        var results: [YouTubeVideo] = []
        var seen = Set<String>()
        func add(_ shorts: [YouTubeVideo]) {
            for short in shorts where seen.insert(short.videoId).inserted {
                results.append(short)
            }
        }

        let bundle = try await self.homeBundle(forceRefresh: false)
        add(bundle.feed.shorts)

        // `#shorts` search is the deepest single source (~30) and is fast.
        add((try? await self.searchShortsFallback()) ?? [])

        // Only reach for the destination feeds (several requests) if still thin.
        if results.count < 40 {
            add(await self.publicDestinationShorts())
        }

        self.logger.info("YouTube Shorts aggregated: \(results.count)")
        return results
    }

    private func publicDestinationShorts() async -> [YouTubeVideo] {
        var collected: [YouTubeVideo] = []
        var seen = Set<String>()
        for destination in [YouTubeDestination.news, .sports, .gaming, .learning, .live] {
            do {
                let feed = try await self.getDestinationFeed(destination)
                for short in feed.shorts where seen.insert(short.videoId).inserted {
                    collected.append(short)
                }
                if collected.count >= 30 {
                    break
                }
            } catch {
                self.logger.debug("Shorts fallback destination failed: \(destination.rawValue, privacy: .public) — \(error.localizedDescription, privacy: .public)")
            }
        }
        return Array(collected.prefix(30))
    }

    private func searchShortsFallback() async throws -> [YouTubeVideo] {
        let data = try await self.request("search", body: ["query": "#shorts"], ttl: APICache.TTL.search)
        let feed = YouTubeFeedParser.parse(data)
        var seen = Set<String>()
        return feed.shorts.filter { seen.insert($0.videoId).inserted }
    }

    // MARK: - Subscriptions & Library

    func getSubscriptionsFeed() async throws -> YouTubeFeed {
        self.logger.info("Fetching YouTube subscriptions feed")

        let data = try await self.request(
            "browse",
            body: ["browseId": "FEsubscriptions"],
            ttl: APICache.TTL.home
        )
        return YouTubeFeedParser.parse(data)
    }

    func getSubscribedChannels() async throws -> [YouTubeChannel] {
        self.logger.info("Fetching subscribed channels via guide")

        let data = try await self.request("guide", body: [:], ttl: APICache.TTL.library)
        return GuideParser.subscribedChannels(data)
    }

    func getHistory(forceRefresh: Bool) async throws -> YouTubeFeed {
        self.logger.info("Fetching YouTube watch history\(forceRefresh ? " (forced)" : "")")

        let data = try await self.request(
            "browse",
            body: ["browseId": "FEhistory"],
            ttl: APICache.TTL.search,
            bypassCache: forceRefresh
        )
        return YouTubeFeedParser.parse(data)
    }

    func getUserPlaylists() async throws -> [YouTubePlaylist] {
        self.logger.info("Fetching YouTube user playlists")

        let data = try await self.request(
            "browse",
            body: ["browseId": "FEplaylist_aggregation"],
            ttl: APICache.TTL.library
        )
        return YouTubeFeedParser.collectPlaylists(data)
    }

    // MARK: - Notifications

    func getNotifications() async throws -> [YouTubeNotification] {
        self.logger.info("Fetching YouTube notification inbox")

        let data = try await self.request(
            "notification/get_notification_menu",
            body: ["notificationsMenuRequestType": "NOTIFICATIONS_MENU_REQUEST_TYPE_INBOX"],
            retry: false
        )
        return YouTubeNotificationsParser.parse(data)
    }

    // MARK: - Actions

    func rateVideo(videoId: String, rating: YouTubeRating) async throws {
        self.logger.info("Rating YouTube video")

        let body: [String: Any] = ["target": ["videoId": videoId]]
        _ = try await self.request(rating.endpoint, body: body, retry: false)
        self.cache.invalidate(matching: Self.cachePrefix)
    }

    func setSubscribed(_ subscribed: Bool, channelId: String) async throws {
        self.logger.info("\(subscribed ? "Subscribing to" : "Unsubscribing from") channel")

        let endpoint = subscribed ? "subscription/subscribe" : "subscription/unsubscribe"
        let body: [String: Any] = ["channelIds": [channelId]]
        _ = try await self.request(endpoint, body: body, retry: false)
        self.cache.invalidate(matching: Self.cachePrefix)
    }

    /// Changes the notification "bell" preference for a subscribed channel. The
    /// `params` come from a `ChannelNotificationPreference.Option` (YouTube's own
    /// `modifyChannelNotificationPreferenceEndpoint` params).
    func modifyNotificationPreference(params: String) async throws {
        self.logger.info("Modifying channel notification preference")

        _ = try await self.request("notification/modify_channel_preference", body: ["params": params], retry: false)
        APICache.shared.invalidate(matching: Self.cachePrefix)
    }

    /// Fetches the video "Report" (flag) form: the list of reason options, each
    /// carrying its own submit `params`. `params` come from
    /// `WatchNextData.reportParams` (YouTube's own report endpoint token), so
    /// this just replays the web client's `flag/get_form` step. Signed-in only.
    func getReportForm(params: String) async throws -> YouTubeReportForm {
        self.logger.info("Fetching video report form")

        let data = try await self.request(
            "flag/get_form",
            body: ["params": params],
            retry: false
        )
        return ReportFormParser.parse(data)
    }

    /// Submits a video report by replaying YouTube's own `flag/flag` step.
    /// `params` are a reason's `submitParams` from `getReportForm(params:)`;
    /// nothing here is fabricated, so this only ever files the report the user
    /// picked. Signed-in only.
    func submitReport(params: String) async throws {
        self.logger.info("Submitting video report")

        _ = try await self.request("flag/flag", body: ["params": params], retry: false)
    }

    /// Saves an entire playlist to the library. YouTube models "save playlist"
    /// as a like on the playlist target (the same `like/like` request the web
    /// client's playlist "Save" button sends), so the saved playlist then shows
    /// up under the user's playlists.
    func savePlaylistToLibrary(playlistId: String) async throws {
        self.logger.info("Saving playlist to library")
        let cleanId = playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId
        let body: [String: Any] = ["target": ["playlistId": cleanId]]
        _ = try await self.request("like/like", body: body, retry: false)
        APICache.shared.invalidate(matching: Self.cachePrefix)
    }

    /// Removes a saved playlist from the library by undoing the save "like".
    func removePlaylistFromLibrary(playlistId: String) async throws {
        self.logger.info("Removing playlist from library")
        let cleanId = playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId
        let body: [String: Any] = ["target": ["playlistId": cleanId]]
        _ = try await self.request("like/removelike", body: body, retry: false)
        APICache.shared.invalidate(matching: Self.cachePrefix)
    }

    func addToWatchLater(videoId: String) async throws {
        try await self.editPlaylist(playlistId: "WL", actions: [
            ["addedVideoId": videoId, "action": "ACTION_ADD_VIDEO"],
        ])
    }

    func removeFromWatchLater(videoId: String) async throws {
        try await self.editPlaylist(playlistId: "WL", actions: [
            ["removedVideoId": videoId, "action": "ACTION_REMOVE_VIDEO_BY_VIDEO_ID"],
        ])
    }

    /// The "Save to…" menu for a video: the user's playlists (Watch Later, plus
    /// their own), each flagged with whether the video is already in it, and
    /// whether a new playlist can be created. Same `addToPlaylistRenderer` the
    /// YouTube web "Save" dialog uses, so `PlaylistParser` handles it as-is.
    func getAddToPlaylistOptions(videoId: String) async throws -> AddToPlaylistMenu {
        self.logger.info("Fetching add-to-playlist options")
        let data = try await self.request(
            "playlist/get_add_to_playlist",
            body: ["videoIds": [videoId]],
            ttl: APICache.TTL.library
        )
        return PlaylistParser.parseAddToPlaylistMenu(data)
    }

    func addToPlaylist(videoId: String, playlistId: String) async throws {
        try await self.editPlaylist(playlistId: playlistId, actions: [
            ["addedVideoId": videoId, "action": "ACTION_ADD_VIDEO"],
        ])
    }

    func removeFromPlaylist(videoId: String, playlistId: String) async throws {
        // ACTION_REMOVE_VIDEO_BY_VIDEO_ID removes by videoId without needing the
        // per-item setVideoId (same as Watch Later), so the Save popover can
        // un-save straight from the add-to-playlist menu.
        try await self.editPlaylist(playlistId: playlistId, actions: [
            ["removedVideoId": videoId, "action": "ACTION_REMOVE_VIDEO_BY_VIDEO_ID"],
        ])
    }

    /// Creates a playlist seeded with the given videos and returns its ID.
    func createPlaylist(title: String, privacyStatus: PlaylistPrivacyStatus, videoIds: [String]) async throws -> String {
        self.logger.info("Creating YouTube playlist")
        var body: [String: Any] = [
            "title": title,
            "privacyStatus": privacyStatus.rawValue,
        ]
        if !videoIds.isEmpty {
            body["videoIds"] = videoIds
        }
        let data = try await self.request("playlist/create", body: body, retry: false)
        guard let playlistId = PlaylistParser.parseCreatedPlaylistId(data) else {
            throw YTMusicError.parseError(message: "Missing playlist ID in create response")
        }
        APICache.shared.invalidate(matching: Self.cachePrefix)
        return playlistId
    }

    private func editPlaylist(playlistId: String, actions: [[String: Any]]) async throws {
        self.logger.info("Editing playlist")
        let cleanId = playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId
        let body: [String: Any] = [
            "playlistId": cleanId,
            "actions": actions,
        ]
        _ = try await self.request("browse/edit_playlist", body: body, retry: false)
        self.cache.invalidate(matching: Self.cachePrefix)
    }

    // MARK: - Request Core

    private enum RequestAuthPolicy {
        case optional
        case required
    }

    private struct RequestAuthHeaders {
        let headers: [String: String]
        let authenticated: Bool
        let authIdentityGeneration: UInt64?
    }

    private func authPolicy(forEndpoint endpoint: String, body: [String: Any]) -> RequestAuthPolicy {
        if Self.authRequiredActionEndpoints.contains(endpoint) {
            return .required
        }

        if endpoint == "guide" {
            return .required
        }

        if endpoint == "browse", let browseId = body["browseId"] as? String {
            if Self.authRequiredBrowseIds.contains(browseId)
                || browseId == "VLWL"
                || browseId == "VLLL"
            {
                return .required
            }
        }

        return .optional
    }

    private func buildRequestHeaders(authPolicy: RequestAuthPolicy) async throws -> RequestAuthHeaders {
        if self.authService.hasPersonalAccount {
            let authIdentityGeneration = self.authService.accountIdentityGeneration
            do {
                let headers = try await self.buildAuthHeaders()
                guard authIdentityGeneration == self.authService.accountIdentityGeneration,
                      self.authService.hasPersonalAccount
                else {
                    throw CancellationError()
                }
                return RequestAuthHeaders(
                    headers: headers,
                    authenticated: true,
                    authIdentityGeneration: authIdentityGeneration
                )
            } catch {
                if error is CancellationError {
                    throw error
                }
                try self.validateAuthIdentity(
                    authenticated: true,
                    generation: authIdentityGeneration
                )
                self.authService.sessionExpired(ifIdentityGenerationMatches: authIdentityGeneration)
                throw YTMusicError.authExpired
            }
        } else if authPolicy == .required {
            throw YTMusicError.notAuthenticated
        }

        return RequestAuthHeaders(
            headers: Self.unauthenticatedHeaders,
            authenticated: false,
            authIdentityGeneration: nil
        )
    }

    private static let unauthenticatedHeaders: [String: String] = [
        "Origin": origin,
        "Referer": origin,
        "Content-Type": "application/json",
    ]

    private static let authRequiredBrowseIds: Set<String> = [
        "FEsubscriptions",
        "FElibrary",
        "FEhistory",
        "FEplaylist_aggregation",
    ]

    private static let authRequiredActionEndpoints: Set<String> = [
        "like/like",
        "like/dislike",
        "like/removelike",
        "subscription/subscribe",
        "subscription/unsubscribe",
        "browse/edit_playlist",
        "playlist/get_add_to_playlist",
        "playlist/create",
        "comment/create_comment",
        "comment/perform_comment_action",
        "notification/get_notification_menu",
        "flag/get_form",
        "flag/flag",
    ]

    /// Builds authentication headers with the YouTube (not music) origin.
    private func buildAuthHeaders() async throws -> [String: String] {
        // Snapshot cookies once per request; deriving the cookie header and SAPISID from
        // the same snapshot avoids repeated WebKit cookie-store enumerations during API fanout.
        let authMaterial = await webKitManager.authMaterial(for: "youtube.com")
        self.logger.debug("Building YouTube auth headers - total cookies: \(authMaterial.totalCookieCount), youtube.com cookies: \(authMaterial.domainCookieCount)")

        guard let cookieHeader = authMaterial.cookieHeader else {
            self.logger.error("No cookies found for youtube.com domain")
            throw YTMusicError.notAuthenticated
        }

        guard let sapisid = authMaterial.sapisid else {
            self.logger.error("SAPISID cookie not found or expired")
            throw YTMusicError.authExpired
        }

        let timestamp = Int(Date().timeIntervalSince1970)
        let sapisidhash = InnerTubeSupport.sapisidHash(
            sapisid: sapisid,
            origin: Self.origin,
            timestamp: timestamp
        )

        return [
            "Cookie": cookieHeader,
            "Authorization": "SAPISIDHASH \(sapisidhash)",
            "Origin": Self.origin,
            "Referer": Self.origin,
            "Content-Type": "application/json",
            // Kaset's account model is primary + brand accounts: selection is
            // expressed via context.user.onBehalfOfUser (brandIdProvider), not
            // the authuser index — same contract as YTMusicClient.
            "X-Goog-AuthUser": "0",
            "X-Origin": Self.origin,
        ]
    }

    /// Builds the standard `WEB` client context payload.
    private func buildContext(authenticated: Bool) -> [String: Any] {
        var userDict: [String: Any] = [
            "lockedSafetyMode": false,
        ]

        if authenticated, let brandId = self.brandIdProvider?() {
            userDict["onBehalfOfUser"] = brandId
        }

        return [
            "client": [
                "clientName": "WEB",
                "clientVersion": Self.clientVersion,
                "hl": SettingsManager.shared.contentLanguage.apiLanguageCode,
                "gl": SettingsManager.shared.contentLanguage.apiRegionCode,
                "browserName": "Safari",
                "browserVersion": "17.0",
                "osName": "Macintosh",
                "osVersion": "10_15_7",
                "platform": "DESKTOP",
                "userAgent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                "utcOffsetMinutes": TimeZone.current.secondsFromGMT() / 60,
            ],
            "user": userDict,
        ]
    }

    /// Makes a request with optional authentication, caching, and retry.
    private func request(
        _ endpoint: String,
        body: [String: Any],
        ttl: TimeInterval? = nil,
        retry: Bool = true,
        bypassCache: Bool = false,
        authPolicy explicitAuthPolicy: RequestAuthPolicy? = nil
    ) async throws -> [String: Any] {
        // Capture generation and logical request order before auth-header awaits
        // so invalidations and later requests still reject stale writes.
        let cacheGeneration = self.cache.generation
        let cacheWriteTicket = ttl.flatMap { _ in
            self.cache.prepareWrite(cacheGeneration: cacheGeneration)
        }
        defer {
            if let cacheWriteTicket {
                self.cache.finishWrite(cacheWriteTicket)
            }
        }
        let authPolicy = explicitAuthPolicy ?? self.authPolicy(forEndpoint: endpoint, body: body)
        let requestAuth = try await self.buildRequestHeaders(authPolicy: authPolicy)

        var fullBody = body
        fullBody["context"] = self.buildContext(authenticated: requestAuth.authenticated)

        let cacheKey = self.cacheKey(
            forEndpoint: Self.cachePrefix + endpoint,
            body: fullBody,
            ttl: ttl,
            authenticated: requestAuth.authenticated
        )
        if let cacheKey, !bypassCache, let cached = self.cache.get(key: cacheKey) {
            self.logger.debug("Cache hit for \(Self.cachePrefix)\(endpoint)")
            return cached
        }

        let cacheWrite = cacheKey.flatMap { key in
            cacheWriteTicket.flatMap { self.cache.beginWrite(for: key, ticket: $0) }
        }

        let json: [String: Any] = if retry {
            try await RetryPolicy.default.execute { [self] in
                try await self.performRequest(
                    endpoint,
                    fullBody: fullBody,
                    headers: requestAuth.headers,
                    authenticated: requestAuth.authenticated,
                    authIdentityGeneration: requestAuth.authIdentityGeneration
                )
            }
        } else {
            try await self.performRequest(
                endpoint,
                fullBody: fullBody,
                headers: requestAuth.headers,
                authenticated: requestAuth.authenticated,
                authIdentityGeneration: requestAuth.authIdentityGeneration
            )
        }

        // Only cache if no account switch / sign-out happened during the request
        // (the cache generation is unchanged); otherwise this could write the
        // previous account's private data under a still-`pending` scope.
        if let ttl, let cacheKey, let cacheWrite {
            self.cache.setIfCurrent(
                key: cacheKey,
                data: json,
                ttl: ttl,
                reservation: cacheWrite
            )
        }

        return json
    }

    private static func cacheScope(accountIdentity: String, brandId: String) -> String {
        let brand = brandId.isEmpty ? "primary" : brandId
        return "account=\(accountIdentity);brand=\(brand)"
    }

    /// Stable account identity used to scope cache keys before the real account
    /// loads. On cold launch `accountCacheIdentityProvider` is empty until
    /// `fetchAccounts()` (a network call) resolves — previously that disabled
    /// caching entirely, so the home feed/chips/shelves all ran as cold ~2 MB
    /// misses. Scoping to a fixed `"pending"` identity instead lets the cold
    /// window reuse its own responses. It cannot leak across accounts: the
    /// `nil → resolved` account transition runs `APICache.invalidateAll()` and
    /// rebuilds the YouTube view models (`MainWindow` account `onChange`), so the
    /// pending entries are cleared the moment a real identity lands.
    private static let pendingAccountScope = "pending"

    /// Derives the cache key for an endpoint+body. Authenticated entries are
    /// scoped to the resolved account identity (or `pendingAccountScope` during
    /// cold launch); signed-out entries use a distinct guest scope.
    /// Returns `nil` only when the call is not cacheable (`ttl == nil`).
    private func cacheKey(
        forEndpoint endpoint: String,
        body: [String: Any],
        ttl: TimeInterval?,
        authenticated: Bool
    ) -> String? {
        guard ttl != nil else { return nil }
        if !authenticated {
            return APICache.stableCacheKey(endpoint: endpoint, body: body, brandId: "guest")
        }

        let brandId = self.brandIdProvider?() ?? ""
        let scopeIdentity = self.accountCacheIdentityProvider?().flatMap { $0.isEmpty ? nil : $0 }
            ?? Self.pendingAccountScope
        return APICache.stableCacheKey(
            endpoint: endpoint,
            body: body,
            brandId: Self.cacheScope(accountIdentity: scopeIdentity, brandId: brandId)
        )
    }

    /// Like `request()`, but returns the raw response bytes instead of a
    /// deserialized `[String: Any]`. Used for the ~2 MB home feed so the caller
    /// can deserialize and parse off the main actor. Caching is the caller's
    /// responsibility (it caches the bytes only after a successful parse, so a
    /// transient non-JSON 200 can't poison the cache).
    private func requestData(
        _ endpoint: String,
        body: [String: Any],
        retry: Bool = true,
        requestAuth precomputedAuth: RequestAuthHeaders? = nil
    ) async throws -> Data {
        let requestAuth: RequestAuthHeaders
        if let precomputedAuth {
            requestAuth = precomputedAuth
        } else {
            let authPolicy = self.authPolicy(forEndpoint: endpoint, body: body)
            requestAuth = try await self.buildRequestHeaders(authPolicy: authPolicy)
        }

        var fullBody = body
        fullBody["context"] = self.buildContext(authenticated: requestAuth.authenticated)

        if retry {
            return try await RetryPolicy.default.execute { [self] in
                try await self.performRequestData(
                    endpoint,
                    fullBody: fullBody,
                    headers: requestAuth.headers,
                    authenticated: requestAuth.authenticated,
                    authIdentityGeneration: requestAuth.authIdentityGeneration
                )
            }
        }
        return try await self.performRequestData(
            endpoint,
            fullBody: fullBody,
            headers: requestAuth.headers,
            authenticated: requestAuth.authenticated,
            authIdentityGeneration: requestAuth.authIdentityGeneration
        )
    }

    /// Cache key for the raw home-bundle bytes.
    private func homeDataCacheKey(body: [String: Any], authenticated: Bool) -> String? {
        var fullBody = body
        fullBody["context"] = self.buildContext(authenticated: authenticated)
        return self.cacheKey(
            forEndpoint: Self.cachePrefix + "data:browse",
            body: fullBody,
            ttl: APICache.TTL.home,
            authenticated: authenticated
        )
    }

    /// Returns cached raw home bytes for an already-scoped `key`.
    ///
    /// The caller resolves optional auth before constructing this key, so guest
    /// and authenticated Home responses live in separate cache scopes. The key
    /// is captured before network awaits so stale account/sign-out completions
    /// cannot write through a later scope.
    private func cachedHomeData(key: String) -> Data? {
        if let cached = self.cache.getData(key: key) {
            self.logger.debug("Cache hit (data) for \(Self.cachePrefix)browse")
            return cached
        }
        return nil
    }

    /// Performs the actual network request.
    private func performRequest(
        _ endpoint: String,
        fullBody: [String: Any],
        headers: [String: String],
        authenticated: Bool,
        authIdentityGeneration: UInt64?
    ) async throws -> [String: Any] {
        try self.validateAuthIdentity(
            authenticated: authenticated,
            generation: authIdentityGeneration
        )
        var components = URLComponents(string: "\(Self.baseURL)/\(endpoint)")
        components?.queryItems = [
            URLQueryItem(name: "prettyPrint", value: "false"),
        ]
        guard let url = components?.url else {
            throw YTMusicError.unknown(message: "Invalid API URL for endpoint: \(endpoint)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = authenticated

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: fullBody)

        self.logger.debug("Making YouTube request to \(endpoint)")

        let result = try await Self.performNetworkRequest(request: request, session: self.session)
        try self.validateAuthIdentity(
            authenticated: authenticated,
            generation: authIdentityGeneration
        )

        switch result {
        case let .success(data):
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw YTMusicError.parseError(message: "Response is not a JSON object")
            }
            return json
        case let .authError(statusCode):
            self.logger.error("YouTube auth error: HTTP \(statusCode)")
            if authenticated {
                if let authIdentityGeneration {
                    self.authService.sessionExpired(ifIdentityGenerationMatches: authIdentityGeneration)
                }
                throw YTMusicError.authExpired
            }
            throw YTMusicError.notAuthenticated
        case let .httpError(statusCode):
            self.logger.error("YouTube API error: HTTP \(statusCode)")
            throw YTMusicError.apiError(message: "HTTP \(statusCode)", code: statusCode)
        case let .networkError(error):
            throw YTMusicError.networkError(underlying: error)
        }
    }

    /// Like `performRequest`, but returns the raw response bytes (no
    /// deserialize) so the caller can parse off the main actor.
    private func performRequestData(
        _ endpoint: String,
        fullBody: [String: Any],
        headers: [String: String],
        authenticated: Bool,
        authIdentityGeneration: UInt64?
    ) async throws -> Data {
        try self.validateAuthIdentity(
            authenticated: authenticated,
            generation: authIdentityGeneration
        )
        var components = URLComponents(string: "\(Self.baseURL)/\(endpoint)")
        components?.queryItems = [
            URLQueryItem(name: "prettyPrint", value: "false"),
        ]
        guard let url = components?.url else {
            throw YTMusicError.unknown(message: "Invalid API URL for endpoint: \(endpoint)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = authenticated

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: fullBody)

        self.logger.debug("Making YouTube request (data) to \(endpoint)")

        let result = try await Self.performNetworkRequest(request: request, session: self.session)
        try self.validateAuthIdentity(
            authenticated: authenticated,
            generation: authIdentityGeneration
        )

        switch result {
        case let .success(data):
            return data
        case let .authError(statusCode):
            self.logger.error("YouTube auth error: HTTP \(statusCode)")
            if authenticated {
                if let authIdentityGeneration {
                    self.authService.sessionExpired(ifIdentityGenerationMatches: authIdentityGeneration)
                }
                throw YTMusicError.authExpired
            }
            throw YTMusicError.notAuthenticated
        case let .httpError(statusCode):
            self.logger.error("YouTube API error: HTTP \(statusCode)")
            throw YTMusicError.apiError(message: "HTTP \(statusCode)", code: statusCode)
        case let .networkError(error):
            throw YTMusicError.networkError(underlying: error)
        }
    }

    // MARK: - Ask Request Identity

    private struct AskRevisionKey: Hashable {
        let conversationID: UUID
        let revision: UInt64
    }

    struct AskRequestSnapshot: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        let videoID: String
        let authenticationGeneration: UInt64
        let accountBinding: YouTubeAskAccountBinding
        let clientGeneration: UInt64
        let headers: [String: String]
        let context: [String: Any]

        var description: String {
            "<redacted YouTube Ask request snapshot>"
        }

        var debugDescription: String {
            self.description
        }

        var customMirror: Mirror {
            Mirror(reflecting: self.description)
        }
    }

    func makeAskRequestSnapshot(videoID: String) async throws -> AskRequestSnapshot {
        guard self.authService.hasPersonalAccount,
              let accountBinding = self.currentAskAccountBinding()
        else {
            throw YouTubeAskClientError.authenticationRequired
        }
        let requestAuth: RequestAuthHeaders
        do {
            requestAuth = try await self.buildRequestHeaders(authPolicy: .required)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw YouTubeAskClientError.authenticationRequired
        }
        guard requestAuth.authenticated,
              let authenticationGeneration = requestAuth.authIdentityGeneration
        else {
            throw YouTubeAskClientError.authenticationRequired
        }
        let snapshot = AskRequestSnapshot(
            videoID: videoID,
            authenticationGeneration: authenticationGeneration,
            accountBinding: accountBinding,
            clientGeneration: self.askSessionGeneration,
            headers: requestAuth.headers,
            context: self.buildContext(authenticated: true)
        )
        try self.validateAskRequestSnapshot(snapshot)
        return snapshot
    }

    func validateAskRequestSnapshot(_ snapshot: AskRequestSnapshot) throws {
        try self.validateAskIdentity(
            authenticationGeneration: snapshot.authenticationGeneration,
            accountBinding: snapshot.accountBinding,
            clientGeneration: snapshot.clientGeneration
        )
    }

    func validateAskIdentity(
        authenticationGeneration: UInt64,
        accountBinding: YouTubeAskAccountBinding,
        clientGeneration: UInt64
    ) throws {
        guard self.authService.hasPersonalAccount,
              authenticationGeneration == self.authService.accountIdentityGeneration,
              clientGeneration == self.askSessionGeneration,
              accountBinding == self.currentAskAccountBinding()
        else {
            throw CancellationError()
        }
    }

    func makeAskRequest(
        endpoint: String,
        bodyData: Data,
        snapshot: AskRequestSnapshot,
        clickTrackingContextData: Data? = nil
    ) throws -> URLRequest {
        guard endpoint == "get_panel",
              var body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        else {
            throw YouTubeAskClientError.invalidResponse
        }
        var context = snapshot.context
        if let clickTrackingContextData {
            guard let clickTrackingContext = try JSONSerialization.jsonObject(
                with: clickTrackingContextData
            ) as? [String: Any],
                let clickTracking = clickTrackingContext["clickTracking"] as? [String: Any]
            else {
                throw YouTubeAskClientError.invalidResponse
            }
            context["clickTracking"] = clickTracking
        }
        body["context"] = context

        var components = URLComponents(string: "\(Self.baseURL)/\(endpoint)")
        components?.queryItems = [
            URLQueryItem(name: "prettyPrint", value: "false"),
        ]
        guard let url = components?.url else {
            throw YouTubeAskClientError.invalidResponse
        }

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
        )
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        for (key, value) in snapshot.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func consumeAskBootstrap(conversationID: UUID) -> Bool {
        self.consumedAskBootstraps.insert(conversationID).inserted
    }

    func consumeAskRevision(
        conversationID: UUID,
        revision: UInt64
    ) -> Bool {
        self.consumedAskRevisions.insert(AskRevisionKey(
            conversationID: conversationID,
            revision: revision
        )).inserted
    }

    func handleAskAuthenticationFailure(snapshot: AskRequestSnapshot) {
        self.authService.sessionExpired(
            ifIdentityGenerationMatches: snapshot.authenticationGeneration
        )
    }

    func nextAskClientMessageID() -> String {
        self.askMessageIDGenerator.next()
    }

    private func currentAskAccountBinding() -> YouTubeAskAccountBinding? {
        guard self.askRequestProfile != nil, self.authService.hasPersonalAccount else { return nil }
        return self.askAccountBindingProvider?()
    }

    private func validateAuthIdentity(authenticated: Bool, generation: UInt64?) throws {
        guard authenticated else { return }
        guard let generation,
              generation == self.authService.accountIdentityGeneration,
              self.authService.hasPersonalAccount
        else {
            throw CancellationError()
        }
    }

    // MARK: - Nonisolated Network Helper

    /// Result type for network requests to avoid throwing across actor boundaries.
    private enum NetworkResult {
        case success(Data)
        case authError(statusCode: Int)
        case httpError(statusCode: Int)
        case networkError(Error)
    }

    // Performs network request off the main thread.
    // swiftformat:disable:next modifierOrder
    nonisolated private static func performNetworkRequest(
        request: URLRequest,
        session: URLSession
    ) async throws -> NetworkResult {
        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .networkError(URLError(.badServerResponse))
            }

            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                return .authError(statusCode: httpResponse.statusCode)
            }

            guard (200 ... 299).contains(httpResponse.statusCode) else {
                return .httpError(statusCode: httpResponse.statusCode)
            }

            return .success(data)
        } catch let error as CancellationError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            return .networkError(error)
        }
    }
}
