import Foundation

/// One channel credited on a collaboration video. YouTube renders multi-channel
/// uploads with a stacked-avatar owner and a "Collaborators" picker instead of a
/// single Subscribe button, so the classic single-channel owner parse comes back
/// empty. Each collaborator carries everything needed to show — and act on — its
/// own Subscribe button and notification "bell".
struct VideoCollaborator: Identifiable, Hashable {
    let channelId: String
    let name: String
    let isVerified: Bool
    /// The channel handle, e.g. "@VirtualCarbon".
    let handle: String?
    /// The subscriber-count text, e.g. "246K subscribers".
    let subscriberText: String?
    let avatarURL: URL?
    /// The subscribed state at load time (from the response's entity store).
    let isSubscribed: Bool
    /// The notification "bell" menu (levels + params), when YouTube exposed it.
    let notification: ChannelNotificationPreference?

    var id: String { self.channelId }

    /// The secondary line for the picker row, e.g. "@VirtualCarbon • 246K subscribers".
    var detail: String? {
        [self.handle, self.subscriberText].compactMap(\.self).joined(separator: " • ")
            .nonEmpty
    }
}

private extension String {
    var nonEmpty: String? { self.isEmpty ? nil : self }
}
