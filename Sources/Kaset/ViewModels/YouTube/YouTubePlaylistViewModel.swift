import Foundation
import Observation

/// View model for a YouTube playlist page.
@MainActor
@Observable
final class YouTubePlaylistViewModel {
    /// Current loading state.
    private(set) var loadingState: LoadingState = .idle

    /// Loaded playlist detail.
    private(set) var detail: YouTubePlaylistDetail?

    /// Whether the playlist is saved to the user's library. Optimistically
    /// toggled by `toggleSaved()`; reverted if the mutation fails.
    private(set) var isSaved = false

    /// True while a save/unsave mutation is in flight, so the button can gate
    /// re-taps.
    private(set) var isSaveInFlight = false

    let playlistId: String
    /// Invalidates stale in-flight loads when a newer one starts
    /// (SwiftUI restarts .task during launch/layout churn; latest wins).
    private var loadGeneration = 0

    let client: any YouTubeClientProtocol
    private let logger = DiagnosticsLogger.api

    init(playlistId: String, client: any YouTubeClientProtocol) {
        self.playlistId = playlistId
        self.client = client
    }

    func load() async {
        self.loadGeneration += 1
        let generation = self.loadGeneration
        self.loadingState = .loading
        do {
            let detail = try await self.client.getPlaylist(playlistId: self.playlistId)
            guard generation == self.loadGeneration else { return }
            self.detail = detail
            self.loadingState = .loaded
        } catch {
            guard generation == self.loadGeneration else { return }
            // A cancelled load (view went away mid-flight) is not an
            // error; reset so the next task run reloads.
            if error is CancellationError {
                self.loadingState = .idle
                return
            }
            self.logger.error("Failed to load YouTube playlist: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    /// Saves the playlist to the library (or removes it when already saved),
    /// mirroring how albums are saved elsewhere. Applies the new state
    /// optimistically and reverts if the API call fails.
    func toggleSaved() async {
        guard !self.isSaveInFlight else { return }
        let wasSaved = self.isSaved
        self.isSaveInFlight = true
        self.isSaved.toggle()
        defer { self.isSaveInFlight = false }
        do {
            if wasSaved {
                try await self.client.removePlaylistFromLibrary(playlistId: self.playlistId)
            } else {
                try await self.client.savePlaylistToLibrary(playlistId: self.playlistId)
            }
        } catch {
            self.isSaved = wasSaved
            self.logger.error("Failed to \(wasSaved ? "remove" : "save") YouTube playlist: \(error.localizedDescription)")
        }
    }
}
