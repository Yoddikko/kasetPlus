import Foundation
import Observation

/// GitHub sign-in via OAuth **Device Flow** — the right fit for a native app:
/// the user is shown a short code to enter at github.com/login/device, and no
/// client secret is needed. The resulting token authorizes creating issues,
/// commenting, and voting/creating discussions.
///
/// Requires `GitHubConfig.clientID` to be set to a real OAuth App client ID.
@MainActor
@Observable
final class GitHubAuthService {
    static let shared = GitHubAuthService()

    struct DeviceCode {
        let userCode: String
        let deviceCode: String
        let verificationURL: URL
        let interval: Int
    }

    enum State: Equatable {
        case signedOut
        case connecting
        case awaitingAuthorization(userCode: String, verificationURL: URL)
        case signedIn(GitHubUser)
    }

    private(set) var state: State = .signedOut

    /// The bearer token for authorized requests (nil when signed out).
    private(set) var token: String?

    var isSignedIn: Bool {
        if case .signedIn = self.state { return true }
        return false
    }

    /// The user access token is the real secret here — kept in the Keychain, not
    /// UserDefaults, and never committed.
    private let keychain = KeychainCredentialStore()
    private var pollTask: Task<Void, Never>?

    private init() {
        // Read the token off the init critical path.
        Task {
            if let saved = self.keychain.getGitHubToken(), !saved.isEmpty {
                self.token = saved
                await self.restoreSession()
            }
        }
    }

    // MARK: - Login

    /// Begins device-flow login: requests a code and starts polling for the token.
    func startLogin() async {
        guard GitHubConfig.isLoginConfigured else { return }
        self.pollTask?.cancel()
        self.state = .connecting
        do {
            let code = try await self.requestDeviceCode()
            self.state = .awaitingAuthorization(userCode: code.userCode, verificationURL: code.verificationURL)
            self.pollTask = Task { await self.pollForToken(code) }
        } catch {
            self.state = .signedOut
        }
    }

    func cancelLogin() {
        self.pollTask?.cancel()
        self.pollTask = nil
        if !self.isSignedIn {
            self.state = .signedOut
        }
    }

    func signOut() {
        self.pollTask?.cancel()
        self.token = nil
        self.keychain.removeGitHubToken()
        self.state = .signedOut
    }

    // MARK: - Device flow

    private func requestDeviceCode() async throws -> DeviceCode {
        var request = URLRequest(url: URL(string: "https://github.com/login/device/code")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "client_id=\(GitHubConfig.clientID)&scope=\(GitHubConfig.scopes)"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?.data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let userCode = json["user_code"] as? String,
              let deviceCode = json["device_code"] as? String,
              let verificationURI = json["verification_uri"] as? String,
              let url = URL(string: verificationURI)
        else {
            throw GitHubError.deviceCodeFailed
        }
        return DeviceCode(
            userCode: userCode,
            deviceCode: deviceCode,
            verificationURL: url,
            interval: (json["interval"] as? Int) ?? 5
        )
    }

    private func pollForToken(_ code: DeviceCode) async {
        var interval = code.interval
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(interval))
            if Task.isCancelled { return }
            do {
                if let token = try await self.exchangeToken(deviceCode: code.deviceCode) {
                    self.token = token
                    try? self.keychain.saveGitHubToken(token)
                    await self.restoreSession()
                    return
                }
            } catch GitHubError.slowDown {
                interval += 5
            } catch GitHubError.authorizationPending {
                continue
            } catch {
                self.state = .signedOut
                return
            }
        }
    }

    /// Returns the token on success, nil while pending, or throws on error.
    private func exchangeToken(deviceCode: String) async throws -> String? {
        var request = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "client_id=\(GitHubConfig.clientID)&device_code=\(deviceCode)"
            + "&grant_type=urn:ietf:params:oauth:grant-type:device_code"
        request.httpBody = body.data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if let token = json["access_token"] as? String {
            return token
        }
        switch json["error"] as? String {
        case "authorization_pending": throw GitHubError.authorizationPending
        case "slow_down": throw GitHubError.slowDown
        default: throw GitHubError.tokenExchangeFailed
        }
    }

    /// Loads the authenticated user for the stored token.
    private func restoreSession() async {
        guard let token else { return }
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                self.signOut()
                return
            }
            let user = try JSONDecoder().decode(GitHubUser.self, from: data)
            self.state = .signedIn(user)
        } catch {
            self.signOut()
        }
    }
}

enum GitHubError: Error {
    case notConfigured
    case notAuthenticated
    case deviceCodeFailed
    case authorizationPending
    case slowDown
    case tokenExchangeFailed
    case requestFailed(Int)
    case decodingFailed
}
