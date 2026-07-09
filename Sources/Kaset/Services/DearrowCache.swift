import Foundation

/// Centralized DeArrow title cache. Fetches community-submitted accurate
/// titles from the DeArrow API and makes them available to any view.
///
/// Views show original titles immediately; the cache fetches in the
/// background and `@Observable` triggers live UI updates when results
/// arrive.
@MainActor
@Observable
final class DearrowCache {
    static let shared = DearrowCache()

    /// DeArrow title keyed by videoId.
    private var dearrowTitles: [String: String] = [:]
    /// Original YouTube title, stored so the toggle can restore it.
    private var originalTitles: [String: String] = [:]
    /// Video IDs currently being fetched (dedup).
    private var inFlight: Set<String> = []

    private init() {}

    // MARK: - Public API

    /// Returns the DeArrow title if available, otherwise the original.
    func displayTitle(for videoId: String, original: String) -> String {
        // Store original for toggle support
        if originalTitles[videoId] == nil {
            originalTitles[videoId] = original
        }
        return dearrowTitles[videoId] ?? original
    }

    /// Whether a DeArrow replacement exists for this video.
    func hasDearrow(for videoId: String) -> Bool {
        dearrowTitles[videoId] != nil
    }

    /// The original YouTube title (for toggle back).
    func originalTitle(for videoId: String) -> String? {
        originalTitles[videoId]
    }

    /// Batch-fetch DeArrow data for multiple videos. Deduplicates and
    /// limits concurrency. Call from view models when video lists load.
    func fetchBatch(for videoIds: [String]) {
        guard SettingsManager.shared.dearrowEnabled else { return }
        for id in videoIds {
            fetchOneIfNeeded(videoId: id)
        }
    }

    /// Fetch a single video. Safe to call from anywhere.
    func fetchOneIfNeeded(videoId: String) {
        guard SettingsManager.shared.dearrowEnabled,
              dearrowTitles[videoId] == nil,
              !inFlight.contains(videoId)
        else { return }

        inFlight.insert(videoId)
        Task {
            await self._fetch(videoId: videoId)
            self.inFlight.remove(videoId)
        }
    }

    // MARK: - Private

    private func _fetch(videoId: String) async {
        guard let url = URL(string: "https://sponsor.ajay.app/api/branding?videoID=\(videoId)") else {
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let titlesList = json["titles"] as? [[String: Any]],
                  let first = titlesList.first
            else { return }

            let isOriginal = first["original"] as? Bool ?? true
            guard !isOriginal,
                  let newTitle = first["title"] as? String,
                  !newTitle.isEmpty
            else { return }

            self.dearrowTitles[videoId] = newTitle
        } catch {
            // Silently ignore — no DeArrow data for this video
        }
    }
}
