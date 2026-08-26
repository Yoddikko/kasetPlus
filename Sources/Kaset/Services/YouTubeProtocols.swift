import Foundation

// MARK: - YouTubeClientProtocol

/// Protocol for the regular YouTube (video) API client.
///
/// Parallel to `YTMusicClientProtocol` but mapped to YouTube's content
/// model (videos, channels, subscriptions) rather than YouTube Music's
/// (songs, albums, artists). Enables dependency injection and mocking.
@MainActor
protocol YouTubeClientProtocol: Sendable {
    /// Clears client-held pagination/session state when auth/account mode changes.
    func resetSessionStateForAccountSwitch()

    // MARK: Home feed

    /// Fetches the recommended home feed (`FEwhat_to_watch`).
    func getHomeFeed() async throws -> YouTubeFeed

    /// Fetches the home feed, its filter chips, and its titled shelves from a
    /// single `FEwhat_to_watch` request, parsed off the main actor. Preferred
    /// over calling `getHomeFeed`/`getHomeChips`/`getHomeShelves` separately:
    /// the ~2 MB response is fetched and walked once instead of three times.
    /// A forced refresh bypasses and replaces the scoped Home cache.
    func getHomeBundle(forceRefresh: Bool) async throws -> YouTubeHomeBundle

    /// Fetches the next page of the home feed, or `nil` when exhausted.
    func getHomeFeedContinuation() async throws -> YouTubeFeed?

    /// Whether more home feed pages are available.
    var hasMoreHomeFeed: Bool { get }

    /// Fetches the personalized filter-chip topics from the home feed
    /// (Gaming, Music, AI, …), each browsable into a topic-filtered rail.
    func getHomeChips() async throws -> [YouTubeHomeChip]

    /// Fetches the titled shelves the home response itself returns (e.g.
    /// "Breaking news"), preserving each shelf's title and videos.
    func getHomeShelves() async throws -> [YouTubeHomeSection]

    /// Browses a home filter chip's continuation token into a personalized,
    /// topic-filtered feed for a home rail.
    func getHomeTopicFeed(continuation: String, forceRefresh: Bool) async throws -> YouTubeFeed

    // MARK: Search

    /// Searches YouTube, optionally applying an opaque filter `params` token
    /// (from a `YouTubeSearchFilterGroup.Option`).
    func search(query: String, params: String?) async throws -> YouTubeSearchResponse

    /// Fetches the next page of the current search, or `nil` when exhausted.
    func getSearchContinuation() async throws -> YouTubeSearchResponse?

    /// Fetches the next page for an explicit search continuation token.
    func getSearchContinuation(continuation: String) async throws -> YouTubeSearchResponse?

    // MARK: Watch

    /// Fetches watch-page companion data (metadata + related videos).
    func getWatchNext(videoId: String, playlistId: String?) async throws -> WatchNextData

    /// Fetches the `player` playability status, used to gate members-only videos
    /// the signed-in user can't watch (shows YouTube's own notice, not a spinner).
    func getPlayability(videoId: String) async throws -> YouTubePlayability

    /// Fetches normal watch data and an optional Ask Gemini bootstrap from one
    /// shared `next` response.
    func getWatchPage(videoId: String, playlistId: String?) async throws -> YouTubeWatchPage

    /// Lazily materializes an Ask panel, or promotes direct bootstrap chips into
    /// a conversation without generating an answer.
    func loadAskConversation(
        from bootstrap: YouTubeAskBootstrap
    ) async throws -> YouTubeAskConversation

    /// Submits exactly one server-issued suggestion in the current conversation.
    func continueAskConversation(
        _ conversation: YouTubeAskConversation,
        selecting suggestionID: YouTubeAskSuggestion.ID
    ) async throws -> YouTubeAskConversation

    /// Submits one validated free-text prompt using the current watch-scoped
    /// server command. A validated composer command may be reused only after
    /// each successful response advances the bound conversation revision.
    func continueAskConversation(
        _ conversation: YouTubeAskConversation,
        submitting userInputText: String,
        playerOffsetMilliseconds: Int64
    ) async throws -> YouTubeAskConversation

    /// Fetches a page of comments by continuation token.
    func getComments(continuation: String) async throws -> YouTubeCommentsPage

    /// Fetches one page of a live stream's chat by continuation token.
    func getLiveChat(continuation: String) async throws -> YouTubeLiveChatPage

    /// Sends a live-chat message using the send params from a live-chat page.
    func sendLiveChatMessage(text: String, params: String) async throws

    /// Posts a top-level comment.
    func postComment(text: String, createCommentParams: String) async throws

    /// Performs a comment toolbar action (like/dislike) by action token.
    func performCommentAction(_ action: String) async throws

    // MARK: Browse

    /// Fetches a channel page by `UC…` channel ID.
    func getChannel(channelId: String) async throws -> YouTubeChannelDetail

    /// Fetches a specific channel tab (Videos, Shorts, Live, Playlists).
    func getChannelTab(channelId: String, tab: YouTubeChannelTab) async throws -> YouTubeChannelTabContent

    /// Loads the next page of a channel tab's videos from a continuation token.
    func getChannelTabContinuation(token: String) async throws -> ([YouTubeVideo], continuation: String?)

    /// Fetches a playlist page by playlist ID (without the `VL` prefix).
    func getPlaylist(playlistId: String) async throws -> YouTubePlaylistDetail

    /// Fetches a public destination feed (Gaming, News, …) for Explore.
    func getDestinationFeed(_ destination: YouTubeDestination) async throws -> YouTubeFeed

    /// Fetches Shorts for the dedicated Shorts surface.
    func getShorts() async throws -> [YouTubeVideo]

    /// Fetches the next page of any public browse feed by continuation token.
    func getFeedContinuation(continuation: String) async throws -> YouTubeFeed

    /// Fetches the next page of an account-scoped browse feed by continuation token.
    func getPrivateFeedContinuation(continuation: String) async throws -> YouTubeFeed

    // MARK: Subscriptions & Library

    /// Fetches the subscriptions feed (`FEsubscriptions`).
    func getSubscriptionsFeed() async throws -> YouTubeFeed

    /// Fetches the signed-in user's subscribed channels (from `guide`).
    func getSubscribedChannels() async throws -> [YouTubeChannel]

    /// Fetches watch history (`FEhistory`). Pass `forceRefresh: true` to bypass
    /// the cached response — used to rebuild Continue Watching right after a
    /// video is watched, where the warm 2 min entry would re-serve the
    /// pre-watch resume percent.
    func getHistory(forceRefresh: Bool) async throws -> YouTubeFeed

    /// Fetches the signed-in user's playlists.
    func getUserPlaylists() async throws -> [YouTubePlaylist]

    // MARK: Notifications

    /// Fetches the notification bell inbox.
    func getNotifications() async throws -> [YouTubeNotification]

    // MARK: Actions

    /// Rates a video (like / dislike / remove rating).
    func rateVideo(videoId: String, rating: YouTubeRating) async throws

    /// Subscribes to or unsubscribes from a channel.
    func setSubscribed(_ subscribed: Bool, channelId: String) async throws

    /// Changes the notification "bell" preference for a subscribed channel
    /// (params from a `ChannelNotificationPreference.Option`).
    func modifyNotificationPreference(params: String) async throws

    /// Saves an entire playlist to the signed-in user's library.
    func savePlaylistToLibrary(playlistId: String) async throws

    /// Removes a previously-saved playlist from the library.
    func removePlaylistFromLibrary(playlistId: String) async throws

    /// Adds a video to Watch Later.
    func addToWatchLater(videoId: String) async throws

    /// Removes a video from Watch Later.
    func removeFromWatchLater(videoId: String) async throws

    /// The "Save to…" menu: user playlists + whether the video is already in each.
    func getAddToPlaylistOptions(videoId: String) async throws -> AddToPlaylistMenu

    /// Adds a video to an existing playlist.
    func addToPlaylist(videoId: String, playlistId: String) async throws

    /// Removes a video from a playlist by video ID.
    func removeFromPlaylist(videoId: String, playlistId: String) async throws

    /// Creates a playlist seeded with the given videos; returns its ID.
    func createPlaylist(title: String, privacyStatus: PlaylistPrivacyStatus, videoIds: [String]) async throws -> String

    /// Fetches the video "Report" (flag) form — the reason options, each with its
    /// own submit params. `params` come from `WatchNextData.reportParams`.
    func getReportForm(params: String) async throws -> YouTubeReportForm

    /// Submits a video report (`flag/flag`) using a reason's `submitParams`.
    func submitReport(params: String) async throws
}

// MARK: - YouTubeClientProtocol Convenience

extension YouTubeClientProtocol {
    /// Fetches watch history using the cache (the default for normal loads).
    func getHistory() async throws -> YouTubeFeed {
        try await self.getHistory(forceRefresh: false)
    }

    /// Default so conformers that predate channel tabs (mocks/UI-test client)
    /// still compile; the real `YouTubeClient` overrides this.
    func getChannelTab(channelId _: String, tab _: YouTubeChannelTab) async throws -> YouTubeChannelTabContent {
        .videos([], continuation: nil)
    }

    func getChannelTabContinuation(token _: String) async throws -> ([YouTubeVideo], continuation: String?) {
        ([], nil)
    }

    /// Default so the mock/UI-test client compiles without a notifications backend.
    func getNotifications() async throws -> [YouTubeNotification] {
        []
    }

    /// Defaults so mocks/UI-test clients compile; the real `YouTubeClient` overrides these.
    func getAddToPlaylistOptions(videoId _: String) async throws -> AddToPlaylistMenu {
        AddToPlaylistMenu(title: nil, options: [], canCreatePlaylist: false)
    }

    /// Defaults so mocks/UI-test clients compile; the real `YouTubeClient` overrides these.
    func savePlaylistToLibrary(playlistId _: String) async throws {}

    func removePlaylistFromLibrary(playlistId _: String) async throws {}

    func addToPlaylist(videoId _: String, playlistId _: String) async throws {}

    func removeFromPlaylist(videoId _: String, playlistId _: String) async throws {}

    func createPlaylist(title _: String, privacyStatus _: PlaylistPrivacyStatus, videoIds _: [String]) async throws -> String {
        ""
    }

    /// Default so mocks/UI-test clients compile; the real client overrides this.
    /// Assuming "playable" means members-only gating is simply inactive there.
    func getPlayability(videoId _: String) async throws -> YouTubePlayability {
        .playable
    }

    /// Defaults so mocks/UI-test clients compile; the real `YouTubeClient` overrides these.
    func getReportForm(params _: String) async throws -> YouTubeReportForm {
        YouTubeReportForm(title: nil, reasons: [])
    }

    func submitReport(params _: String) async throws {}
}
