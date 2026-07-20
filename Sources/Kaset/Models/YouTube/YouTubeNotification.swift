import Foundation

// MARK: - YouTubeNotification

/// A single entry from YouTube's notification bell (a new upload, live stream,
/// comment reply, …). Mirrors the `notificationRenderer` the web client shows
/// in the notifications inbox.
struct YouTubeNotification: Identifiable, Hashable {
    let id: String
    /// The bell copy, e.g. "Veritasium uploaded: How To Slow Aging".
    let message: String
    /// Relative time the notification was sent, e.g. "3 hours ago".
    let sentTimeText: String?
    /// Content thumbnail (video still) or channel avatar.
    let thumbnailURL: URL?
    /// The new video the notification points at. Opens in the app's native
    /// watch view. We currently only surface new-video notifications, so this
    /// is always present.
    let videoId: String
}
