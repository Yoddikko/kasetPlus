import Foundation

/// ListenBrainz scrobbling service.
///
/// Unlike Last.fm (browser OAuth + a signing proxy), ListenBrainz authenticates
/// with a single **user token** the user pastes in Settings — no app secret, no
/// proxy. Listens are submitted directly to `api.listenbrainz.org` with a
/// `Authorization: Token <token>` header.
@MainActor
@Observable
final class ListenBrainzService: ScrobbleServiceProtocol {
    let serviceName = "ListenBrainz"

    private(set) var authState: ScrobbleAuthState = .disconnected

    private let credentialStore: KeychainCredentialStore
    private let session: URLSession
    private let apiBaseURL: URL
    private let logger = DiagnosticsLogger.scrobbling

    /// The user token used for authenticated submissions.
    @ObservationIgnored private var token: String?

    init(
        credentialStore: KeychainCredentialStore = KeychainCredentialStore(),
        apiBaseURL: URL = URL(string: "https://api.listenbrainz.org")!,
        session: URLSession = .shared
    ) {
        self.credentialStore = credentialStore
        self.apiBaseURL = apiBaseURL
        self.session = session
    }

    // MARK: - Authentication

    func restoreSession() {
        if let token = self.credentialStore.getListenBrainzToken(),
           let username = self.credentialStore.getListenBrainzUsername()
        {
            self.token = token
            self.authState = .connected(username: username)
            self.logger.info("Restored ListenBrainz session for user: \(username)")
        }
    }

    /// ListenBrainz has no browser flow; the settings row calls `connect(token:)`.
    func authenticate() async throws {
        throw ScrobbleError.invalidResponse("ListenBrainz connects with a user token — paste it in Settings.")
    }

    /// Validates and stores a user token, connecting the account.
    func connect(token: String) async throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ScrobbleError.invalidCredentials }

        self.authState = .authenticating
        do {
            let username = try await self.validate(token: trimmed)
            try self.credentialStore.saveListenBrainzToken(trimmed)
            try self.credentialStore.saveListenBrainzUsername(username)
            self.token = trimmed
            self.authState = .connected(username: username)
            // Connecting a token implies the user wants it on.
            SettingsManager.shared.setServiceEnabled(self.serviceName, true)
            self.logger.info("Connected to ListenBrainz as: \(username)")
        } catch {
            let message = (error as? ScrobbleError)?.errorDescription ?? error.localizedDescription
            self.authState = .error(message)
            self.logger.error("ListenBrainz connect failed: \(message)")
            throw error
        }
    }

    func disconnect() async {
        self.token = nil
        self.credentialStore.removeListenBrainzCredentials()
        self.authState = .disconnected
        self.logger.info("Disconnected from ListenBrainz")
    }

    func validateSession() async throws -> Bool {
        guard let token = self.token else { return false }
        do {
            _ = try await self.validate(token: token)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Submission

    func updateNowPlaying(_ track: ScrobbleTrack) async throws {
        guard let token = self.token else { throw ScrobbleError.sessionExpired }
        let body = Self.submissionBody(listenType: "playing_now", tracks: [track], includeTimestamp: false)
        let data = try JSONSerialization.data(withJSONObject: body)
        try await self.submit(data, token: token)
        self.logger.debug("ListenBrainz now playing: \(track.title) by \(track.artist)")
    }

    func scrobble(_ tracks: [ScrobbleTrack]) async throws -> [ScrobbleResult] {
        guard let token = self.token else { throw ScrobbleError.sessionExpired }
        guard !tracks.isEmpty else { return [] }

        let body = Self.submissionBody(listenType: "import", tracks: tracks, includeTimestamp: true)
        let data = try JSONSerialization.data(withJSONObject: body)
        try await self.submit(data, token: token)
        self.logger.info("Scrobbled \(tracks.count) track(s) to ListenBrainz")

        // ListenBrainz accepts the batch as a whole (HTTP 2xx) or throws, so a
        // successful submit means every track was accepted.
        return tracks.map { ScrobbleResult(track: $0, accepted: true) }
    }

    // MARK: - Payload Builders (pure — unit tested)

    /// Builds a `submit-listens` request body for the given listen type.
    /// `import`/`single` include `listened_at`; `playing_now` must not.
    static func submissionBody(listenType: String, tracks: [ScrobbleTrack], includeTimestamp: Bool) -> [String: Any] {
        let payload = tracks.map { track -> [String: Any] in
            var entry: [String: Any] = ["track_metadata": Self.trackMetadata(for: track)]
            if includeTimestamp {
                entry["listened_at"] = Int(track.timestamp.timeIntervalSince1970)
            }
            return entry
        }
        return ["listen_type": listenType, "payload": payload]
    }

    static func trackMetadata(for track: ScrobbleTrack) -> [String: Any] {
        var additionalInfo: [String: Any] = [
            "media_player": "KasetPlus",
            "submission_client": "KasetPlus",
            "music_service_name": "YouTube Music",
        ]
        if let duration = track.duration, duration > 0 {
            additionalInfo["duration_ms"] = Int(duration * 1000)
        }
        if let videoId = track.videoId {
            additionalInfo["origin_url"] = "https://music.youtube.com/watch?v=\(videoId)"
        }

        var metadata: [String: Any] = [
            "artist_name": track.artist,
            "track_name": track.title,
            "additional_info": additionalInfo,
        ]
        if let album = track.album, !album.isEmpty {
            metadata["release_name"] = album
        }
        return metadata
    }

    // MARK: - Network

    // swiftformat:disable modifierOrder
    /// POSTs a submit-listens body. Throws a mapped `ScrobbleError` on failure.
    nonisolated private func submit(_ bodyData: Data, token: String) async throws {
        var request = URLRequest(url: self.apiBaseURL.appendingPathComponent("1/submit-listens"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = bodyData

        let (data, response) = try await self.session.data(for: request)
        try Self.checkStatus(response, data: data)
    }

    /// Validates a token and returns the associated username.
    nonisolated private func validate(token: String) async throws -> String {
        var request = URLRequest(url: self.apiBaseURL.appendingPathComponent("1/validate-token"))
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await self.session.data(for: request)
        try Self.checkStatus(response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ScrobbleError.invalidResponse("Invalid validate-token response")
        }
        guard (json["valid"] as? Bool) == true else {
            throw ScrobbleError.invalidCredentials
        }
        return (json["user_name"] as? String) ?? "ListenBrainz"
    }

    /// Maps an HTTP response to a `ScrobbleError` (or returns on 2xx).
    nonisolated static func checkStatus(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ScrobbleError.invalidResponse("Non-HTTP response")
        }
        switch http.statusCode {
        case 200 ... 299:
            return
        case 401:
            throw ScrobbleError.invalidCredentials
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw ScrobbleError.rateLimited(retryAfter: retryAfter)
        case 500 ... 599:
            throw ScrobbleError.serviceUnavailable
        default:
            let message = String(data: data, encoding: .utf8)?.prefix(120) ?? ""
            throw ScrobbleError.invalidResponse("ListenBrainz error (\(http.statusCode)): \(message)")
        }
    }
    // swiftformat:enable modifierOrder
}
