import Foundation
import Observation

/// Tracks whether the user is a KasetPlus supporter (via Ko-fi) and drives the
/// "Support the project" button and sheet.
///
/// ⚠️ The real Ko-fi verification is **not wired yet** — a supporter's status
/// can only be set through the DEBUG `simulate…` flow so the UI states can be
/// tested end-to-end without a Ko-fi backend. `refreshFromKofi()` is the seam
/// where the real check will go. In release builds `tier` therefore stays
/// `.none` until that seam is implemented.
@MainActor
@Observable
final class SupportManager {
    static let shared = SupportManager()

    enum Tier: Equatable {
        /// Not a supporter.
        case none
        /// A one-off tip grants supporter status for a limited window (~1 month).
        case oneTime(until: Date)
        /// An active monthly Ko-fi membership.
        case subscription
    }

    private(set) var tier: Tier

    /// Fork's Ko-fi tip page (one-time), grants supporter status in the app.
    static let forkKofiURL = URL(string: "https://ko-fi.com/yodddd")!
    /// Fork's Ko-fi memberships (recurring) page.
    static let forkMembershipURL = URL(string: "https://ko-fi.com/yodddd/tiers")!
    /// Upstream Kaset's Ko-fi — supporting it is appreciated but grants NO status here.
    static let baseKofiURL = URL(string: "https://ko-fi.com/sozercan")!

    private static let defaultsKey = "support.tier"
    private static let untilKey = "support.tier.until"
    private static let emailKey = "support.email"
    /// How long a one-time tip keeps supporter status.
    static let oneTimeDuration: TimeInterval = 30 * 24 * 60 * 60

    /// The Ko-fi email the user verified with, if any (re-checked on launch so a
    /// lapsed subscription stops counting).
    private(set) var verifiedEmail: String?

    private let session: URLSession = .shared

    /// Base URL of the fork's Cloudflare Worker (the one that receives Ko-fi
    /// webhooks and answers `/kofi/verify`). Reuses the Last.fm worker config so
    /// there's nothing extra to set once that worker is deployed.
    static let workerBaseURL: URL? = {
        let env = ProcessInfo.processInfo.environment
        let candidates = [
            env["KASET_SUPPORT_WORKER_URL"],
            Bundle.main.object(forInfoDictionaryKey: "SupportWorkerURL") as? String,
            Bundle.main.object(forInfoDictionaryKey: "LastFMWorkerURL") as? String,
            env["KASET_LASTFM_WORKER_URL"],
        ]
        for case let string? in candidates {
            if let url = URL(string: string) { return url }
        }
        return nil
    }()

    /// Whether real Ko-fi verification is wired (a worker URL is configured).
    var isVerificationConfigured: Bool { Self.workerBaseURL != nil }

    private init() {
        self.tier = Self.loadTier()
        self.verifiedEmail = UserDefaults.standard.string(forKey: Self.emailKey)
    }

    /// Whether the user currently counts as a supporter (an active subscription,
    /// or a one-time tip still inside its window).
    var isSupporter: Bool {
        switch self.tier {
        case .none:
            false
        case let .oneTime(until):
            until > .now
        case .subscription:
            true
        }
    }

    /// The one-time window's end, when that's the active tier.
    var oneTimeExpiry: Date? {
        if case let .oneTime(until) = self.tier, until > .now {
            return until
        }
        return nil
    }

    // MARK: - Ko-fi verification

    enum VerifyResult: Equatable {
        case supporter
        case notFound
        case notConfigured
        case failed
    }

    /// Verifies a Ko-fi email against the worker (`/kofi/verify`) and, on
    /// success, records the tier + remembers the email for future refreshes.
    @discardableResult
    func verify(email rawEmail: String) async -> VerifyResult {
        let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !email.isEmpty else { return .notFound }
        guard let base = Self.workerBaseURL,
              var components = URLComponents(url: base.appendingPathComponent("kofi/verify"), resolvingAgainstBaseURL: false)
        else {
            return .notConfigured
        }
        components.queryItems = [URLQueryItem(name: "email", value: email)]
        guard let url = components.url else { return .failed }

        do {
            let (data, response) = try await self.session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return .failed
            }
            guard payload["supporter"] as? Bool == true else {
                return .notFound
            }
            let tierString = payload["tier"] as? String
            let expiry = (payload["expiry"] as? Double).map { Date(timeIntervalSince1970: $0) }
            let tier: Tier = tierString == "subscription"
                ? .subscription
                : .oneTime(until: expiry ?? .now.addingTimeInterval(Self.oneTimeDuration))
            self.setTier(tier)
            self.setVerifiedEmail(email)
            return .supporter
        } catch {
            return .failed
        }
    }

    /// Re-checks the remembered email so a lapsed subscription or expired tip
    /// stops counting. Safe to call on launch.
    func refreshFromKofi() async {
        guard let email = self.verifiedEmail, Self.workerBaseURL != nil else { return }
        let result = await self.verify(email: email)
        // A hard "not found" means the status lapsed; drop it.
        if result == .notFound {
            self.setTier(.none)
        }
    }

    /// Forgets the verified email and clears status (used to "sign out" of support).
    func forgetVerification() {
        self.setVerifiedEmail(nil)
        self.setTier(.none)
    }

    // MARK: - Supporters wall

    /// A public supporter entry (name only — the worker never exposes emails).
    struct Supporter: Identifiable, Hashable {
        let name: String
        let tier: String
        let months: Int
        let lastPaid: Date

        var id: String { "\(self.name)-\(self.lastPaid.timeIntervalSince1970)" }
        var isSubscriber: Bool { self.tier == "subscription" }
    }

    /// Fetches the active supporters (newest payer first) from the worker.
    func fetchSupporters() async -> [Supporter] {
        guard let base = Self.workerBaseURL else { return [] }
        let url = base.appendingPathComponent("kofi/supporters")
        do {
            let (data, response) = try await self.session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let array = object["supporters"] as? [[String: Any]]
            else {
                return []
            }
            return array.map { entry in
                Supporter(
                    name: (entry["name"] as? String) ?? "Anonymous",
                    tier: (entry["tier"] as? String) ?? "onetime",
                    months: (entry["months"] as? Int) ?? 0,
                    lastPaid: Date(timeIntervalSince1970: (entry["updatedAt"] as? Double) ?? 0)
                )
            }
        } catch {
            return []
        }
    }

    private func setVerifiedEmail(_ email: String?) {
        self.verifiedEmail = email
        if let email {
            UserDefaults.standard.set(email, forKey: Self.emailKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.emailKey)
        }
    }

    // MARK: - Persistence

    private func setTier(_ tier: Tier) {
        self.tier = tier
        Self.saveTier(tier)
    }

    private static func loadTier() -> Tier {
        let defaults = UserDefaults.standard
        switch defaults.string(forKey: Self.defaultsKey) {
        case "subscription":
            return .subscription
        case "oneTime":
            return .oneTime(until: Date(timeIntervalSince1970: defaults.double(forKey: Self.untilKey)))
        default:
            return .none
        }
    }

    private static func saveTier(_ tier: Tier) {
        let defaults = UserDefaults.standard
        switch tier {
        case .none:
            defaults.removeObject(forKey: Self.defaultsKey)
            defaults.removeObject(forKey: Self.untilKey)
        case .subscription:
            defaults.set("subscription", forKey: Self.defaultsKey)
            defaults.removeObject(forKey: Self.untilKey)
        case let .oneTime(until):
            defaults.set("oneTime", forKey: Self.defaultsKey)
            defaults.set(until.timeIntervalSince1970, forKey: Self.untilKey)
        }
    }
}
