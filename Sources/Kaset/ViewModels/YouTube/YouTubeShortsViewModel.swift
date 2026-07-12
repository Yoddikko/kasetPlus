import Foundation
import Observation

/// View model for the dedicated Shorts surface.
///
/// Shorts ride along in the home feed response (Kaset strips them from the
/// regular grid); this surfaces them on their own page.
@MainActor
@Observable
final class YouTubeShortsViewModel {
    /// Current loading state.
    private(set) var loadingState: LoadingState = .idle

    /// Shorts to display.
    private(set) var shorts: [YouTubeVideo] = []

    /// Invalidates stale in-flight loads when a newer one starts
    /// (SwiftUI restarts .task during launch/layout churn; latest wins).
    private var loadGeneration = 0

    /// The single in-flight load, shared by concurrent `load()` callers so
    /// SwiftUI `.task` restarts coalesce onto one run instead of duplicating the
    /// Shorts request.
    private var loadTask: Task<Void, Never>?

    let client: any YouTubeClientProtocol
    private let logger = DiagnosticsLogger.api

    /// When seeded from an external list (e.g. a channel's Shorts tab), the
    /// viewer shows exactly that list; `load`/`refresh` don't fetch a new feed.
    private let isSeeded: Bool

    init(client: any YouTubeClientProtocol) {
        self.client = client
        self.isSeeded = false
    }

    /// Seeds the viewer with a fixed list of shorts (already loaded elsewhere)
    /// instead of fetching the global Shorts feed.
    init(client: any YouTubeClientProtocol, seededShorts: [YouTubeVideo]) {
        self.client = client
        self.isSeeded = true
        self.shorts = seededShorts
        self.loadingState = .loaded
    }

    func load() async {
        if case .loaded = self.loadingState {
            return
        }
        if let existing = self.loadTask {
            await existing.value
            return
        }
        self.loadGeneration += 1
        let runID = self.loadGeneration
        let task = Task { await self.performLoad(runID: runID) }
        self.loadTask = task
        await task.value
    }

    private func performLoad(runID: Int) async {
        defer {
            if self.loadGeneration == runID {
                self.loadTask = nil
            }
        }
        guard runID == self.loadGeneration, !Task.isCancelled else { return }
        self.loadingState = .loading
        do {
            let shorts = try await self.client.getShorts()
            guard runID == self.loadGeneration else { return }
            self.shorts = shorts
            self.loadingState = .loaded
        } catch {
            guard runID == self.loadGeneration else { return }
            // A cancelled load (view went away mid-flight) is not an
            // error; reset so the next task run reloads.
            if error is CancellationError {
                self.loadingState = .idle
                return
            }
            self.logger.error("Failed to load Shorts: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    func refresh() async {
        // A seeded viewer has no feed to refresh; keep the injected list.
        guard !self.isSeeded else { return }
        self.cancelLoad()
        self.loadingState = .idle
        self.shorts = []
        await self.load()
    }

    func cancelLoad() {
        self.loadTask?.cancel()
        self.loadTask = nil
        self.loadGeneration += 1
    }
}
