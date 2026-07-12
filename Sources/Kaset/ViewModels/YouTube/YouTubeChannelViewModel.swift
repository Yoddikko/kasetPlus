import Foundation
import Observation

/// View model for a YouTube channel page.
@MainActor
@Observable
final class YouTubeChannelViewModel {
    /// Current loading state.
    private(set) var loadingState: LoadingState = .idle

    /// Loaded channel detail.
    private(set) var detail: YouTubeChannelDetail?

    /// The selected channel tab. `.home` uses `detail.videos`; others load lazily.
    private(set) var selectedTab: YouTubeChannelTab = .home
    /// Cached per-tab content, loaded on first selection.
    private(set) var tabVideos: [YouTubeChannelTab: [YouTubeVideo]] = [:]
    private(set) var tabPlaylists: [YouTubeChannelTab: [YouTubePlaylist]] = [:]
    private(set) var loadingTabs: Set<YouTubeChannelTab> = []
    private(set) var failedTabs: Set<YouTubeChannelTab> = []
    /// Continuation token for each tab's next page (nil = no more).
    private(set) var tabContinuations: [YouTubeChannelTab: String] = [:]
    private(set) var loadingMoreTabs: Set<YouTubeChannelTab> = []
    /// Bumped on every pagination advance so the grid's bottom sentinel re-fires.
    private(set) var paginationTrigger = 0

    /// Whether the given tab has another page to load.
    func hasMore(_ tab: YouTubeChannelTab) -> Bool {
        self.tabContinuations[tab] != nil
    }

    let channelId: String
    /// Invalidates stale in-flight loads when a newer one starts
    /// (SwiftUI restarts .task during launch/layout churn; latest wins).
    private var loadGeneration = 0

    let client: any YouTubeClientProtocol
    private let logger = DiagnosticsLogger.api

    init(channelId: String, client: any YouTubeClientProtocol) {
        self.channelId = channelId
        self.client = client
    }

    func load() async {
        self.loadGeneration += 1
        let generation = self.loadGeneration
        self.loadingState = .loading
        do {
            let detail = try await self.client.getChannel(channelId: self.channelId)
            guard generation == self.loadGeneration else { return }
            self.detail = detail
            // Seed the Home tab so it paginates like the others.
            self.tabVideos[.home] = detail.videos
            self.tabContinuations[.home] = detail.continuation
            self.loadingState = .loaded
        } catch {
            guard generation == self.loadGeneration else { return }
            // A cancelled load (view went away mid-flight) is not an
            // error; reset so the next task run reloads.
            if error is CancellationError {
                self.loadingState = .idle
                return
            }
            self.logger.error("Failed to load YouTube channel: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    /// Switches the visible tab and lazily loads its content the first time.
    func selectTab(_ tab: YouTubeChannelTab) {
        self.selectedTab = tab
        // Home comes from the already-loaded landing detail.
        guard tab != .home else { return }
        let alreadyLoaded = self.tabVideos[tab] != nil || self.tabPlaylists[tab] != nil
        guard !alreadyLoaded, !self.loadingTabs.contains(tab) else { return }
        Task { await self.loadTab(tab) }
    }

    /// Fetches a tab's content (retryable after a failure).
    func loadTab(_ tab: YouTubeChannelTab) async {
        self.loadingTabs.insert(tab)
        self.failedTabs.remove(tab)
        defer { self.loadingTabs.remove(tab) }
        do {
            let content = try await self.client.getChannelTab(channelId: self.channelId, tab: tab)
            switch content {
            case let .videos(videos, continuation):
                self.tabVideos[tab] = videos
                self.tabContinuations[tab] = continuation
            case let .playlists(playlists, continuation):
                self.tabPlaylists[tab] = playlists
                self.tabContinuations[tab] = continuation
            }
        } catch {
            if error is CancellationError { return }
            self.logger.error("Failed to load channel tab \(tab.rawValue): \(error.localizedDescription)")
            self.failedTabs.insert(tab)
        }
    }

    /// Loads the next page of the given tab's videos (bottom-of-grid infinite
    /// scroll). Playlists tabs don't paginate.
    func loadMore(_ tab: YouTubeChannelTab) async {
        guard !tab.showsPlaylists,
              let token = self.tabContinuations[tab],
              !self.loadingMoreTabs.contains(tab)
        else {
            return
        }
        self.loadingMoreTabs.insert(tab)
        defer { self.loadingMoreTabs.remove(tab) }
        do {
            let (videos, next) = try await self.client.getChannelTabContinuation(token: token)
            self.tabVideos[tab, default: []].append(contentsOf: videos)
            self.tabContinuations[tab] = next
            self.paginationTrigger += 1
        } catch {
            if error is CancellationError { return }
            self.logger.error("Failed to load more in channel tab \(tab.rawValue): \(error.localizedDescription)")
            // Stop retrying this tab so the sentinel doesn't loop on a failure.
            self.tabContinuations[tab] = nil
        }
    }
}
