import Foundation

/// Parses YouTube live-chat responses from the `live_chat/get_live_chat`
/// endpoint: text messages plus the token and delay for the next poll.
enum LiveChatParser {
    static func parse(_ data: [String: Any]) -> YouTubeLiveChatPage {
        let liveChat = (data["continuationContents"] as? [String: Any])?["liveChatContinuation"]
            as? [String: Any]

        let actions = liveChat?["actions"] as? [[String: Any]] ?? []
        let messages: [YouTubeLiveChatMessage] = actions.compactMap { action in
            guard let item = (action["addChatItemAction"] as? [String: Any])?["item"] as? [String: Any],
                  let renderer = item["liveChatTextMessageRenderer"] as? [String: Any]
            else {
                return nil
            }
            return Self.message(from: renderer)
        }

        let (continuation, timeoutMs) = Self.nextPoll(from: liveChat)
        return YouTubeLiveChatPage(
            messages: messages,
            continuation: continuation,
            timeoutMs: timeoutMs,
            sendParams: Self.sendParams(from: liveChat)
        )
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    /// Send-message params, present only when the signed-in user may post. Found
    /// under `actionPanel.liveChatMessageInputRenderer.sendButton…`, but the exact
    /// nesting varies, so search recursively for the send endpoint's `params`.
    private static func sendParams(from liveChat: [String: Any]?) -> String? {
        guard let liveChat else { return nil }
        return Self.findSendParams(in: liveChat)
    }

    private static func findSendParams(in value: Any) -> String? {
        if let dict = value as? [String: Any] {
            if let endpoint = dict["sendLiveChatMessageEndpoint"] as? [String: Any],
               let params = endpoint["params"] as? String
            {
                return params
            }
            for nested in dict.values {
                if let found = Self.findSendParams(in: nested) { return found }
            }
        } else if let array = value as? [Any] {
            for element in array {
                if let found = Self.findSendParams(in: element) { return found }
            }
        }
        return nil
    }

    private static func message(from renderer: [String: Any]) -> YouTubeLiveChatMessage? {
        guard let id = renderer["id"] as? String,
              let author = YouTubeItemParser.text(from: renderer["authorName"])
        else {
            return nil
        }

        var isVerified = false
        var isModerator = false
        var isMember = false
        var isOwner = false
        for badge in renderer["authorBadges"] as? [[String: Any]] ?? [] {
            guard let badgeRenderer = badge["liveChatAuthorBadgeRenderer"] as? [String: Any] else { continue }
            if let iconType = (badgeRenderer["icon"] as? [String: Any])?["iconType"] as? String {
                switch iconType {
                case "VERIFIED": isVerified = true
                case "MODERATOR": isModerator = true
                case "OWNER": isOwner = true
                default: break
                }
            } else if badgeRenderer["customThumbnail"] != nil {
                // Member badges carry a custom thumbnail instead of an icon type.
                isMember = true
            }
        }

        return YouTubeLiveChatMessage(
            id: id,
            author: author,
            authorAvatarURL: YouTubeItemParser.thumbnailURL(fromThumbnail: renderer["authorPhoto"]),
            authorChannelId: renderer["authorExternalChannelId"] as? String,
            message: Self.flatten(renderer["message"]),
            timestampText: Self.timestampText(renderer["timestampUsec"]),
            isVerified: isVerified,
            isModerator: isModerator,
            isMember: isMember,
            isOwner: isOwner
        )
    }

    /// Formats a microsecond epoch timestamp (as a string) into a short clock time.
    private static func timestampText(_ value: Any?) -> String? {
        guard let usecString = value as? String, let usec = Double(usecString) else { return nil }
        let date = Date(timeIntervalSince1970: usec / 1_000_000)
        return Self.timeFormatter.string(from: date)
    }

    /// Flattens a `message` runs array into a display string: text runs verbatim,
    /// emoji runs as their unicode character (or `:shortcut:` for custom emoji).
    private static func flatten(_ value: Any?) -> String {
        guard let runs = (value as? [String: Any])?["runs"] as? [[String: Any]] else { return "" }
        var result = ""
        for run in runs {
            if let text = run["text"] as? String {
                result += text
            } else if let emoji = run["emoji"] as? [String: Any] {
                if emoji["isCustomEmoji"] as? Bool == true {
                    result += (emoji["shortcuts"] as? [String])?.first ?? ""
                } else if let emojiId = emoji["emojiId"] as? String {
                    result += emojiId
                }
            }
        }
        return result
    }

    /// The next continuation token and poll delay. Live chat uses either an
    /// `invalidationContinuationData` or a `timedContinuationData`; both carry a
    /// `continuation` and a `timeoutMs`.
    private static func nextPoll(from liveChat: [String: Any]?) -> (String?, Int) {
        let continuations = liveChat?["continuations"] as? [[String: Any]] ?? []
        for continuation in continuations {
            for value in continuation.values {
                guard let data = value as? [String: Any],
                      let token = data["continuation"] as? String
                else { continue }
                let timeout = (data["timeoutMs"] as? Int) ?? 5000
                return (token, timeout)
            }
        }
        return (nil, 5000)
    }
}
