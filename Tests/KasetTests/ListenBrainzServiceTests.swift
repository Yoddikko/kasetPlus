import Foundation
import Testing
@testable import Kaset

@MainActor
@Suite(.serialized, .tags(.service))
struct ListenBrainzServiceTests {
    private func makeTrack() -> ScrobbleTrack {
        ScrobbleTrack(
            title: "Song Title",
            artist: "Artist Name",
            album: "Album Name",
            duration: 210,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            videoId: "abc123"
        )
    }

    @Test("Initial state is disconnected")
    func initialState() {
        let service = ListenBrainzService()
        #expect(service.authState == .disconnected)
        #expect(service.serviceName == "ListenBrainz")
    }

    @Test("Scrobble without token throws sessionExpired")
    func scrobbleWithoutToken() async {
        let service = ListenBrainzService()
        await #expect(throws: ScrobbleError.sessionExpired) {
            _ = try await service.scrobble([self.makeTrack()])
        }
    }

    @Test("UpdateNowPlaying without token throws sessionExpired")
    func nowPlayingWithoutToken() async {
        let service = ListenBrainzService()
        await #expect(throws: ScrobbleError.sessionExpired) {
            try await service.updateNowPlaying(self.makeTrack())
        }
    }

    @Test("Scrobble empty array returns empty results")
    func scrobbleEmpty() async throws {
        // Empty batch short-circuits before the token guard.
        let service = ListenBrainzService()
        let results = try await service.scrobble([])
        #expect(results.isEmpty)
    }

    @Test("Import body carries listened_at and full track metadata")
    func importBody() throws {
        let body = ListenBrainzService.submissionBody(
            listenType: "import",
            tracks: [self.makeTrack()],
            includeTimestamp: true
        )
        #expect(body["listen_type"] as? String == "import")

        let payload = try #require(body["payload"] as? [[String: Any]])
        let entry = try #require(payload.first)
        #expect(entry["listened_at"] as? Int == 1_700_000_000)

        let metadata = try #require(entry["track_metadata"] as? [String: Any])
        #expect(metadata["artist_name"] as? String == "Artist Name")
        #expect(metadata["track_name"] as? String == "Song Title")
        #expect(metadata["release_name"] as? String == "Album Name")

        let info = try #require(metadata["additional_info"] as? [String: Any])
        #expect(info["duration_ms"] as? Int == 210_000)
        #expect(info["music_service_name"] as? String == "YouTube Music")
        #expect(info["submission_client"] as? String == "KasetPlus")
    }

    @Test("Playing-now body omits listened_at")
    func nowPlayingBody() throws {
        let body = ListenBrainzService.submissionBody(
            listenType: "playing_now",
            tracks: [self.makeTrack()],
            includeTimestamp: false
        )
        #expect(body["listen_type"] as? String == "playing_now")

        let payload = try #require(body["payload"] as? [[String: Any]])
        let entry = try #require(payload.first)
        #expect(entry["listened_at"] == nil)
        #expect(entry["track_metadata"] != nil)
    }

    @Test("HTTP status maps to scrobble errors")
    func statusMapping() {
        let url = URL(string: "https://api.listenbrainz.org")!
        func response(_ code: Int) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
        }
        #expect(throws: ScrobbleError.invalidCredentials) {
            try ListenBrainzService.checkStatus(response(401), data: Data())
        }
        #expect(throws: ScrobbleError.serviceUnavailable) {
            try ListenBrainzService.checkStatus(response(503), data: Data())
        }
        // 2xx does not throw.
        #expect(throws: Never.self) {
            try ListenBrainzService.checkStatus(response(200), data: Data())
        }
    }
}
