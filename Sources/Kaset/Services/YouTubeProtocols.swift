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
    func getHomeBundle() async throws -> YouTubeHomeBundle

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
    func getHomeTopicFeed(continuation: String) async throws -> YouTubeFeed

    // MARK: Search

    /// Searches YouTube with an optional result-kind filter.
    func search(query: String, filter: YouTubeSearchFilter) async throws -> YouTubeSearchResponse

    /// Fetches the next page of the current search, or `nil` when exhausted.
    func getSearchContinuation() async throws -> YouTubeSearchResponse?

    /// Fetches the next page for an explicit search continuation token.
    func getSearchContinuation(continuation: String) async throws -> YouTubeSearchResponse?

    // MARK: Watch

    /// Fetches watch-page companion data (metadata + related videos).
    func getWatchNext(videoId: String) async throws -> WatchNextData

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

    /// Adds a video to Watch Later.
    func addToWatchLater(videoId: String) async throws

    /// Removes a video from Watch Later.
    func removeFromWatchLater(videoId: String) async throws
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
}
