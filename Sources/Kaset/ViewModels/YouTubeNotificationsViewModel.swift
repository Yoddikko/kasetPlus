import Foundation
import Observation

/// Drives the notification bell.
///
/// "Seen" state is tracked locally: opening the inbox marks every currently
/// listed notification seen (persisted across launches), so only notifications
/// that arrive afterwards light the badge again. This mirrors YouTube's bell
/// without depending on the server's own read/unseen bookkeeping.
@MainActor
@Observable
final class YouTubeNotificationsViewModel {
    private(set) var notifications: [YouTubeNotification] = []
    /// IDs that were still unseen at the moment the inbox was last opened, so
    /// the popover can highlight what's new for this viewing.
    private(set) var newlyOpenedIds: Set<String> = []
    private(set) var isLoading = false
    private(set) var hasError = false

    /// Badge number: notifications not yet marked seen in the app. Derived so it
    /// can never drift from `notifications`/`seenIds`.
    var unseenCount: Int {
        Set(self.notifications.map(\.id)).subtracting(self.seenIds).count
    }

    private let client: any YouTubeClientProtocol
    private let logger = DiagnosticsLogger.youtubeNotifications
    private var pollTask: Task<Void, Never>?

    /// Persisted set of notification IDs the user has already seen in the app.
    private var seenIds: Set<String>
    private static let seenIdsDefaultsKey = "youtube.notifications.seenIds"

    // ponytail: fixed 3-min poll of the full inbox (needed to know which IDs
    // are new). Response is bounded; widen if it ever shows as load. Polls
    // regardless of window focus — gate on `NSApp.isActive` if battery matters.
    private static let pollInterval: Duration = .seconds(180)

    init(client: any YouTubeClientProtocol) {
        self.client = client
        let stored = UserDefaults.standard.stringArray(forKey: Self.seenIdsDefaultsKey) ?? []
        self.seenIds = Set(stored)
    }

    /// Starts the inbox poll. Safe to call repeatedly.
    func startPolling() {
        guard self.pollTask == nil else { return }
        self.pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refresh(markSeen: false)
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    /// Stops polling and clears in-memory state (used on sign-out). The
    /// persisted seen set is kept so a re-login doesn't resurface old items.
    func stopPolling() {
        self.pollTask?.cancel()
        self.pollTask = nil
        self.notifications = []
        self.newlyOpenedIds = []
        self.hasError = false
    }

    /// Loads the inbox when the bell is opened and marks everything seen.
    func openInbox() async {
        self.isLoading = true
        defer { self.isLoading = false }
        await self.refresh(markSeen: true)
    }

    /// Whether a notification should show the "new" dot in the open inbox.
    func isNew(_ notification: YouTubeNotification) -> Bool {
        self.newlyOpenedIds.contains(notification.id)
    }

    // MARK: - Fetch

    private func refresh(markSeen: Bool) async {
        do {
            let items = try await self.client.getNotifications()
            self.notifications = items
            self.hasError = false

            let currentIds = Set(items.map(\.id))
            var updatedSeen = self.seenIds
            // Drop seen IDs no longer in the inbox so the set stays bounded.
            updatedSeen.formIntersection(currentIds)
            if markSeen {
                self.newlyOpenedIds = currentIds.subtracting(updatedSeen)
                updatedSeen.formUnion(currentIds)
            }

            // Persist only when the set actually changed (avoids a UserDefaults
            // write on every idle poll).
            if updatedSeen != self.seenIds {
                self.seenIds = updatedSeen
                self.persistSeenIds()
            }
        } catch {
            self.hasError = true
            self.logger.error("Notification inbox fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistSeenIds() {
        UserDefaults.standard.set(Array(self.seenIds), forKey: Self.seenIdsDefaultsKey)
    }
}
