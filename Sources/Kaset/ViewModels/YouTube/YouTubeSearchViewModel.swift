import Foundation
import Observation

// MARK: - YouTubeSearchViewModel

/// View model for YouTube search.
@MainActor
@Observable
final class YouTubeSearchViewModel {
    /// Current loading state.
    private(set) var loadingState: LoadingState = .idle

    /// Current search query.
    var query: String = "" {
        didSet {
            self.handleQueryChange(from: oldValue)
        }
    }

    /// Search results.
    private(set) var results: YouTubeSearchResponse = .empty

    /// Filter groups YouTube offers for the current query (Type, Upload date,
    /// Duration, Features, Sort by). Persisted across filter re-searches so the
    /// filter bar stays stable while results reload.
    private(set) var filterGroups: [YouTubeSearchFilterGroup] = []

    /// The applied filter `params` token, or nil when no filter is active.
    private(set) var appliedFilterParams: String?

    /// Whether any search filter is currently applied.
    var hasActiveFilters: Bool { self.appliedFilterParams != nil }

    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var paginationTask: Task<Void, Never>?

    private var searchGeneration = 0
    private var activeSearchRequest: SearchRequest?
    private var activePaginationRequest: PaginationRequest?
    private var publishedSearchContext: SearchContext?
    private var publishedSearchGeneration: Int?

    let client: any YouTubeClientProtocol
    private let logger = DiagnosticsLogger.api

    init(client: any YouTubeClientProtocol) {
        self.client = client
    }

    /// Performs a search for the current query and filter.
    func search() async {
        guard let context = self.currentSearchContext else {
            self.resetForEmptyQuery()
            return
        }

        let start = self.startSearch(for: context, resetResults: false)
        if start.didCreate {
            await self.awaitStartedSearch(start)
        } else {
            await start.task.value
        }
    }

    func cancelSearch() {
        self.invalidateInFlightSearch()
        self.resetForEmptyQuery()
    }

    /// Loads the next page of results.
    func loadMore() async {
        guard self.loadingState == .loaded,
              let continuation = self.results.continuation,
              let context = self.publishedSearchContext,
              let generation = self.publishedSearchGeneration,
              self.isCurrentPublishedSearch(context: context, generation: generation)
        else { return }

        let request = PaginationRequest(context: context, generation: generation, continuation: continuation)
        let start = self.startPagination(request)
        if start.didCreate {
            await self.awaitStartedPagination(start)
        } else {
            await start.task.value
        }
    }

    private var currentSearchContext: SearchContext? {
        let query = Self.normalizedQuery(self.query)
        guard !query.isEmpty else { return nil }
        return SearchContext(query: query, params: self.appliedFilterParams)
    }

    /// Applies a filter option (from `filterGroups`) and re-runs the search.
    func applyFilter(_ option: YouTubeSearchFilterGroup.Option) {
        guard !option.isDisabled, self.appliedFilterParams != option.params else { return }
        self.appliedFilterParams = option.params
        self.handleFilterChange()
    }

    /// Clears all applied filters and re-runs the unfiltered search.
    func clearFilters() {
        guard self.appliedFilterParams != nil else { return }
        self.appliedFilterParams = nil
        self.handleFilterChange()
    }

    private static func normalizedQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func handleQueryChange(from oldValue: String) {
        let oldQuery = Self.normalizedQuery(oldValue)
        let newQuery = Self.normalizedQuery(self.query)
        guard oldQuery != newQuery else { return }

        self.invalidateInFlightSearch()
        // A new query starts fresh: drop any applied filters and their groups.
        self.appliedFilterParams = nil
        self.filterGroups = []

        if newQuery.isEmpty {
            self.resetForEmptyQuery()
        } else if self.publishedSearchContext?.query != newQuery {
            self.results = .empty
            self.loadingState = .idle
            self.publishedSearchContext = nil
            self.publishedSearchGeneration = nil
        }
    }

    private func handleFilterChange() {
        guard let context = self.currentSearchContext else {
            self.invalidateInFlightSearch()
            self.resetForEmptyQuery()
            return
        }

        _ = self.startSearch(for: context, resetResults: true)
    }

    private func startSearch(for context: SearchContext, resetResults: Bool) -> StartedSearch {
        if let searchTask, let activeSearchRequest, activeSearchRequest.context == context {
            return StartedSearch(task: searchTask, request: activeSearchRequest, didCreate: false)
        }

        self.invalidateInFlightSearch()
        if resetResults {
            self.results = .empty
            self.publishedSearchContext = nil
            self.publishedSearchGeneration = nil
        }
        self.loadingState = .loading

        let request = SearchRequest(context: context, generation: self.searchGeneration)
        self.activeSearchRequest = request
        let task = Task {
            await self.performSearch(request)
        }
        self.searchTask = task
        return StartedSearch(task: task, request: request, didCreate: true)
    }

    private func awaitStartedSearch(_ start: StartedSearch) async {
        await start.task.value
    }

    private func performSearch(_ request: SearchRequest) async {
        defer {
            if self.activeSearchRequest == request {
                self.activeSearchRequest = nil
                self.searchTask = nil
            }
        }

        do {
            let results = try await client.search(query: request.context.query, params: request.context.params)
            guard self.isCurrentSearch(request) else { return }
            guard !Task.isCancelled else { return }

            self.results = results
            // Keep the last non-empty filter set so the bar stays put on reloads.
            if !results.filterGroups.isEmpty {
                self.filterGroups = results.filterGroups
            }
            self.publishedSearchContext = request.context
            self.publishedSearchGeneration = request.generation
            self.loadingState = .loaded
        } catch {
            // A cancelled load (view went away mid-flight or a newer search
            // superseded it) is not an error; the next search owns publishing.
            if error is CancellationError {
                return
            }
            guard self.isCurrentSearch(request) else { return }
            guard !Task.isCancelled else { return }
            self.logger.error("YouTube search failed: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    private func startPagination(_ request: PaginationRequest) -> StartedPagination {
        if let paginationTask, self.activePaginationRequest == request {
            return StartedPagination(task: paginationTask, request: request, didCreate: false)
        }

        self.loadingState = .loadingMore
        let task = Task {
            await self.performLoadMore(request)
        }
        self.activePaginationRequest = request
        self.paginationTask = task
        return StartedPagination(task: task, request: request, didCreate: true)
    }

    private func awaitStartedPagination(_ start: StartedPagination) async {
        await start.task.value
    }

    private func performLoadMore(_ request: PaginationRequest) async {
        defer {
            if self.activePaginationRequest == request || self.activePaginationRequest == nil {
                self.activePaginationRequest = nil
                self.paginationTask = nil
            }
        }

        do {
            if let more = try await client.getSearchContinuation(continuation: request.continuation) {
                guard self.isCurrentPagination(request) else { return }
                guard !Task.isCancelled else {
                    self.loadingState = .loaded
                    return
                }

                let existingVideos = Set(self.results.videos.map(\.videoId))
                self.results.videos.append(
                    contentsOf: more.videos.filter { !existingVideos.contains($0.videoId) }
                )
                let existingChannels = Set(self.results.channels.map(\.channelId))
                self.results.channels.append(
                    contentsOf: more.channels.filter { !existingChannels.contains($0.channelId) }
                )
                let existingPlaylists = Set(self.results.playlists.map(\.playlistId))
                self.results.playlists.append(
                    contentsOf: more.playlists.filter { !existingPlaylists.contains($0.playlistId) }
                )
                let existingItems = Set(self.results.items.map(\.id))
                self.results.items.append(
                    contentsOf: more.items.filter { !existingItems.contains($0.id) }
                )
                self.results.continuation = more.continuation
            } else {
                guard self.isCurrentPagination(request) else { return }
                self.results.continuation = nil
            }
            guard self.isCurrentPagination(request) else { return }
            self.loadingState = .loaded
        } catch {
            guard self.isCurrentPagination(request) else { return }
            // A cancelled page load is not an error; allow retrying.
            if error is CancellationError {
                self.loadingState = .loaded
                return
            }
            self.logger.error("YouTube search continuation failed: \(error.localizedDescription)")
            self.loadingState = .loaded
            self.results.continuation = nil
        }
    }

    private func invalidateInFlightSearch() {
        self.searchGeneration += 1
        self.searchTask?.cancel()
        self.searchTask = nil
        self.activeSearchRequest = nil
        _ = self.cancelInFlightPagination()
    }

    private func cancelInFlightPagination() -> Task<Void, Never>? {
        let task = self.paginationTask
        task?.cancel()
        self.activePaginationRequest = nil
        return task
    }

    private func resetForEmptyQuery() {
        self.results = .empty
        self.loadingState = .idle
        self.publishedSearchContext = nil
        self.publishedSearchGeneration = nil
        self.filterGroups = []
        self.appliedFilterParams = nil
    }

    private func isCurrentSearch(_ request: SearchRequest) -> Bool {
        self.activeSearchRequest == request &&
            self.searchGeneration == request.generation &&
            self.currentSearchContext == request.context
    }

    private func isCurrentPublishedSearch(context: SearchContext, generation: Int) -> Bool {
        self.searchGeneration == generation &&
            self.publishedSearchGeneration == generation &&
            self.publishedSearchContext == context &&
            self.currentSearchContext == context
    }

    private func isCurrentPagination(_ request: PaginationRequest) -> Bool {
        self.isCurrentPublishedSearch(context: request.context, generation: request.generation)
    }
}

// MARK: - SearchContext

private struct SearchContext: Equatable {
    let query: String
    let params: String?
}

// MARK: - SearchRequest

private struct SearchRequest: Equatable {
    let context: SearchContext
    let generation: Int
}

// MARK: - PaginationRequest

private struct PaginationRequest: Equatable {
    let context: SearchContext
    let generation: Int
    let continuation: String
}

// MARK: - StartedSearch

private struct StartedSearch {
    let task: Task<Void, Never>
    let request: SearchRequest
    let didCreate: Bool
}

// MARK: - StartedPagination

private struct StartedPagination {
    let task: Task<Void, Never>
    let request: PaginationRequest
    let didCreate: Bool
}
