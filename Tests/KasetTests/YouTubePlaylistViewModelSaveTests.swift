import Foundation
import Testing
@testable import KasetPlus

// MARK: - YouTubePlaylistViewModelSaveTests

/// Covers the "Save to library" toggle for YouTube playlists, mirroring how
/// albums are saved. Uses the configurable mock client to assert the correct
/// save/unsave request is sent and that the optimistic state behaves.
@Suite("YouTubePlaylistViewModel save", .serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
struct YouTubePlaylistViewModelSaveTests {
    let mockClient: MockYouTubeClient
    let sut: YouTubePlaylistViewModel

    init() {
        self.mockClient = MockYouTubeClient()
        self.sut = YouTubePlaylistViewModel(playlistId: "PL123", client: self.mockClient)
    }

    @Test("Toggling save sends a save request and marks the playlist saved")
    func saveSendsRequest() async {
        #expect(!self.sut.isSaved)

        await self.sut.toggleSaved()

        #expect(self.sut.isSaved)
        #expect(self.mockClient.savedPlaylistIds == ["PL123"])
        #expect(self.mockClient.removedPlaylistIds.isEmpty)
        #expect(!self.sut.isSaveInFlight)
    }

    @Test("Toggling save again sends a remove request and clears saved state")
    func unsaveSendsRemoveRequest() async {
        await self.sut.toggleSaved()
        await self.sut.toggleSaved()

        #expect(!self.sut.isSaved)
        #expect(self.mockClient.savedPlaylistIds == ["PL123"])
        #expect(self.mockClient.removedPlaylistIds == ["PL123"])
    }

    @Test("A failed save reverts the optimistic saved state")
    func failedSaveReverts() async {
        self.mockClient.error = YTMusicError.notAuthenticated

        await self.sut.toggleSaved()

        #expect(!self.sut.isSaved)
        #expect(!self.sut.isSaveInFlight)
    }
}
