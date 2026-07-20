import Foundation

/// Parses YouTube's notification endpoints.
///
/// `notification/get_notification_menu` returns the inbox as a
/// `multiPageMenuRenderer` whose section holds one `notificationRenderer` per
/// entry (or a `backgroundPromoRenderer` empty state).
enum YouTubeNotificationsParser {
    /// Extracts inbox notifications from a `get_notification_menu` response.
    static func parse(_ data: [String: Any]) -> [YouTubeNotification] {
        var renderers: [[String: Any]] = []
        Self.collectRenderers(named: "notificationRenderer", in: data, into: &renderers)

        var seen = Set<String>()
        return renderers.enumerated().compactMap { index, renderer in
            Self.notification(from: renderer, fallbackId: index)
        }
        .filter { seen.insert($0.id).inserted }
    }

    // MARK: - Notification Item

    private static func notification(from renderer: [String: Any], fallbackId: Int) -> YouTubeNotification? {
        guard let message = YouTubeItemParser.text(from: renderer["shortMessage"])
            ?? YouTubeItemParser.text(from: renderer["longMessage"])
            ?? YouTubeItemParser.text(from: renderer["text"])
        else {
            return nil
        }

        let navigationEndpoint = renderer["navigationEndpoint"]
        // Only surface new-video notifications: drop anything without a video target.
        guard let videoId = Self.firstWatchVideoId(in: navigationEndpoint)
            ?? Self.videoId(fromURLPath: Self.destinationPath(in: navigationEndpoint))
        else {
            return nil
        }

        let id = (renderer["notificationId"] as? String) ?? "notification-\(fallbackId)"
        let thumbnailURL = YouTubeItemParser.thumbnailURL(fromThumbnail: renderer["videoThumbnail"])
            ?? YouTubeItemParser.thumbnailURL(fromThumbnail: renderer["thumbnail"])

        return YouTubeNotification(
            id: id,
            message: message,
            sentTimeText: YouTubeItemParser.text(from: renderer["sentTimeText"]),
            thumbnailURL: thumbnailURL,
            videoId: videoId
        )
    }

    // MARK: - Endpoint Traversal

    private static func firstWatchVideoId(in value: Any?) -> String? {
        if let dict = value as? [String: Any] {
            if let watch = dict["watchEndpoint"] as? [String: Any],
               let videoId = watch["videoId"] as? String, !videoId.isEmpty
            {
                return videoId
            }
            for nested in dict.values {
                if let found = Self.firstWatchVideoId(in: nested) {
                    return found
                }
            }
        } else if let array = value as? [Any] {
            for element in array {
                if let found = Self.firstWatchVideoId(in: element) {
                    return found
                }
            }
        }
        return nil
    }

    /// The relative/absolute URL of the notification's tap target, if any.
    private static func destinationPath(in value: Any?) -> String? {
        guard let dict = value as? [String: Any] else { return nil }
        return (
            (dict["commandMetadata"] as? [String: Any])?["webCommandMetadata"] as? [String: Any]
        )?["url"] as? String
    }

    /// Extracts a `v=` video ID from a `/watch?v=…` URL path.
    private static func videoId(fromURLPath path: String?) -> String? {
        guard let path,
              let components = URLComponents(string: path.hasPrefix("http") ? path : "https://www.youtube.com" + path),
              let videoId = components.queryItems?.first(where: { $0.name == "v" })?.value,
              !videoId.isEmpty
        else {
            return nil
        }
        return videoId
    }

    private static func collectRenderers(named key: String, in value: Any, into result: inout [[String: Any]]) {
        if let dict = value as? [String: Any] {
            if let renderer = dict[key] as? [String: Any] {
                result.append(renderer)
            }
            for nested in dict.values {
                Self.collectRenderers(named: key, in: nested, into: &result)
            }
        } else if let array = value as? [Any] {
            for element in array {
                Self.collectRenderers(named: key, in: element, into: &result)
            }
        }
    }
}
