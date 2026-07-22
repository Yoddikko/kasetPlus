import Foundation

/// The per-channel subscription notification preference — the "bell" shown next
/// to Subscribe once the signed-in user follows a channel.
///
/// The options (and the opaque `params` used to change them) come straight from
/// YouTube's `notificationPreferenceButton` menu in the watch/channel response,
/// so the current selection always reflects the real server state and applying a
/// change just replays YouTube's own `modifyChannelNotificationPreferenceEndpoint`.
struct ChannelNotificationPreference: Hashable {
    /// The notification level. Names follow the user-facing meaning, not
    /// YouTube's (confusing) icon names.
    enum Level: Hashable {
        case all // NOTIFICATIONS_ACTIVE
        case personalized // NOTIFICATIONS_NONE
        case none // NOTIFICATIONS_OFF
        case unknown

        init(iconType: String) {
            switch iconType {
            case "NOTIFICATIONS_ACTIVE": self = .all
            case "NOTIFICATIONS_NONE": self = .personalized
            case "NOTIFICATIONS_OFF": self = .none
            default: self = .unknown
            }
        }

        /// SF Symbol reflecting the level (for the bell button/menu).
        var symbolName: String {
            switch self {
            case .all: "bell.fill"
            case .personalized: "bell.badge.fill"
            case .none: "bell.slash.fill"
            case .unknown: "bell"
            }
        }
    }

    /// One selectable option from YouTube's notification menu.
    struct Option: Hashable, Identifiable {
        let level: Level
        /// Localized label straight from YouTube (e.g. "All" / "Personalized" / "None").
        let label: String
        /// Opaque params to POST to `notification/modify_channel_preference`.
        let params: String
        /// Whether this is the current selection.
        let isCurrent: Bool

        var id: String { self.params }
    }

    let channelId: String
    let options: [Option]
    /// YouTube's own localized "unsubscribe" label (e.g. "Annulla iscrizione"),
    /// so the menu stays in one language alongside the option labels.
    let unsubscribeLabel: String

    /// The currently-selected option, if the API marked one.
    var current: Option? { self.options.first(where: \.isCurrent) }

    /// Current level (for the bell icon), falling back to `.unknown`.
    var currentLevel: Level { self.current?.level ?? .unknown }
}
