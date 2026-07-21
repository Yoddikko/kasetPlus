import Foundation
import Testing
@testable import KasetPlus

/// Tests for YouTubeNotificationsParser.
@Suite(.tags(.parser))
struct YouTubeNotificationsParserTests {
    // MARK: - Empty / Missing

    @Test("Empty response yields no notifications")
    func parseEmpty() {
        #expect(YouTubeNotificationsParser.parse([:]).isEmpty)
    }

    @Test("Empty-state promo yields no notifications")
    func parseEmptyStatePromo() {
        let data: [String: Any] = [
            "actions": [[
                "openPopupAction": ["popup": ["multiPageMenuRenderer": ["sections": [[
                    "backgroundPromoRenderer": ["title": ["simpleText": "Your notifications live here"]],
                ]]]]],
            ]],
        ]
        #expect(YouTubeNotificationsParser.parse(data).isEmpty)
    }

    // MARK: - Notification Items

    @Test("Parses a watch notification with videoId, read flag, and thumbnail")
    func parseWatchNotification() {
        let data = Self.menu(items: [
            Self.notificationRenderer(
                id: "n1",
                message: "Veritasium uploaded: How To Slow Aging",
                sentTime: "3 hours ago",
                read: false,
                videoId: "abc123",
                url: "/watch?v=abc123"
            ),
            Self.notificationRenderer(
                id: "n2",
                message: "Reply to your comment",
                sentTime: "1 day ago",
                read: true,
                videoId: nil,
                url: "/post/xyz"
            ),
        ])

        let notifications = YouTubeNotificationsParser.parse(data)
        // The comment reply (no video target) is dropped: only new videos remain.
        #expect(notifications.count == 1)

        let first = notifications[0]
        #expect(first.id == "n1")
        #expect(first.message == "Veritasium uploaded: How To Slow Aging")
        #expect(first.sentTimeText == "3 hours ago")
        #expect(first.videoId == "abc123")
        #expect(first.thumbnailURL != nil)
    }

    @Test("Derives videoId from a /watch?v= URL when no watchEndpoint is present")
    func parseVideoIdFromURL() {
        let data = Self.menu(items: [
            Self.notificationRenderer(
                id: "n1",
                message: "New comment reply",
                sentTime: nil,
                read: false,
                videoId: nil,
                url: "/watch?v=urlvid42&lc=comment"
            ),
        ])
        #expect(YouTubeNotificationsParser.parse(data).first?.videoId == "urlvid42")
    }

    @Test("Drops notifications without a video target")
    func parseDropsNonVideo() {
        let renderer: [String: Any] = ["notificationRenderer": [
            "notificationId": "c1",
            "shortMessage": ["simpleText": "New post from a channel"],
            "navigationEndpoint": ["browseEndpoint": ["browseId": "UCabc123"]],
        ]]
        #expect(YouTubeNotificationsParser.parse(Self.menu(items: [renderer])).isEmpty)
    }

    @Test("Deduplicates repeated notification IDs")
    func parseDeduplicates() {
        let data = Self.menu(items: [
            Self.notificationRenderer(id: "dup", message: "A", sentTime: nil, read: false, videoId: "vid", url: nil),
            Self.notificationRenderer(id: "dup", message: "A", sentTime: nil, read: false, videoId: "vid", url: nil),
        ])
        #expect(YouTubeNotificationsParser.parse(data).count == 1)
    }

    // MARK: - Fixtures

    private static func menu(items: [[String: Any]]) -> [String: Any] {
        [
            "actions": [[
                "openPopupAction": ["popup": ["multiPageMenuRenderer": ["sections": [[
                    "multiPageMenuNotificationSectionRenderer": ["items": items],
                ]]]]],
            ]],
        ]
    }

    private static func notificationRenderer(
        id: String,
        message: String,
        sentTime: String?,
        read: Bool,
        videoId: String?,
        url: String?
    ) -> [String: Any] {
        var renderer: [String: Any] = [
            "notificationId": id,
            "read": read,
            "shortMessage": ["simpleText": message],
            "thumbnail": ["thumbnails": [["url": "https://i.ytimg.com/\(id).jpg", "width": 320, "height": 180]]],
        ]
        if let sentTime {
            renderer["sentTimeText"] = ["simpleText": sentTime]
        }

        var navigationEndpoint: [String: Any] = [:]
        if let videoId {
            navigationEndpoint["watchEndpoint"] = ["videoId": videoId]
        }
        if let url {
            navigationEndpoint["commandMetadata"] = ["webCommandMetadata": ["url": url]]
        }
        if !navigationEndpoint.isEmpty {
            renderer["navigationEndpoint"] = navigationEndpoint
        }

        return ["notificationRenderer": renderer]
    }
}
