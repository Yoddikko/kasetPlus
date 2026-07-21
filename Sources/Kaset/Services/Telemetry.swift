import Foundation

/// Anonymous, fire-and-forget breakage telemetry.
///
/// It exists to answer one question fast: *did an app update or a YouTube-side
/// change break parsing/playback in the wild?* When the shared API request path
/// hits an unexpected failure (a response that no longer parses, or an
/// unexpected HTTP status), we ping the fork's Worker so the maintainer sees it
/// in Workers Logs within minutes instead of via user reports.
///
/// What we send: an event name, a small string detail (e.g. the endpoint), the
/// app version/build, the macOS version, and a random per-install id. **No
/// account, no PII, no content.** Users can turn it off in Settings
/// (`SettingsManager.telemetryEnabled`); the id is a throwaway UUID, not a
/// device identifier.
@MainActor
enum Telemetry {
    /// Reuses the same Worker the support/Last.fm features already resolve, so
    /// there's nothing extra to configure.
    // ponytail: same 4-candidate lookup as SupportManager; not worth a shared
    // helper for two call sites.
    private static let baseURL: URL? = {
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

    /// Anonymous, stable-per-install id (a throwaway UUID — not the device).
    private static let installID: String = {
        let key = "telemetry.installID"
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: key) { return existing }
        let id = UUID().uuidString
        defaults.set(id, forKey: key)
        return id
    }()

    /// Last time each event was sent, so an outage doesn't flood the endpoint.
    private static var lastSent: [String: Date] = [:]
    private static let debounce: TimeInterval = 60

    /// Reports a breakage event. No-ops when telemetry is disabled or the same
    /// event fired within the debounce window. Never blocks the caller.
    static func report(_ event: String, _ detail: [String: String] = [:]) {
        guard SettingsManager.shared.telemetryEnabled, let base = self.baseURL else { return }

        let now = Date()
        if let previous = self.lastSent[event], now.timeIntervalSince(previous) < self.debounce {
            return
        }
        self.lastSent[event] = now

        let info = Bundle.main.infoDictionary
        let payload: [String: Any] = [
            "event": event,
            "detail": detail,
            "app": "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "id": self.installID,
        ]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var request = URLRequest(url: base.appendingPathComponent("telemetry"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-Kaset-Telemetry")
        request.httpBody = httpBody

        Task.detached { _ = try? await URLSession.shared.data(for: request) }
    }
}
