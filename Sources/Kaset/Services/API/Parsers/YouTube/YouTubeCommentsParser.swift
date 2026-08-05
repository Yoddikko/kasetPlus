import Foundation

/// Parses YouTube comments continuation responses (`next` with the
/// comments section's continuation token).
///
/// Modern responses deliver comment data as `commentEntityPayload`
/// mutations in `frameworkUpdates`; older ones inline `commentRenderer`s.
/// Both are handled.
enum YouTubeCommentsParser {
    /// Like/dislike action tokens from a comment's engagement-toolbar surface
    /// payload (keyed by the view model's `toolbarSurfaceKey`).
    private struct ToolbarSurface {
        let like: String?
        let unlike: String?
        let dislike: String?
        let undislike: String?
    }

    static func parse(_ data: [String: Any]) -> YouTubeCommentsPage {
        var comments = Self.commentsFromEntityPayloads(data)
        if comments.isEmpty {
            comments = Self.commentsFromLegacyRenderers(data)
        }

        let sortTokens = Self.sortTokens(of: data)

        return YouTubeCommentsPage(
            comments: comments,
            continuation: Self.nextPageToken(of: data),
            createCommentParams: Self.firstString(forKey: "createCommentParams", in: data),
            sortTopToken: sortTokens.top,
            sortNewestToken: sortTokens.newest
        )
    }

    // MARK: - Sort Tokens

    /// The comments header exposes a `sortFilterSubMenuRenderer` whose
    /// `subMenuItems` carry the reload continuation tokens: item 0 is
    /// "Top comments", item 1 is "Newest first". Present only on the first
    /// comments page (the response that contains the submenu); nil otherwise.
    private static func sortTokens(of value: Any) -> (top: String?, newest: String?) {
        if let dict = value as? [String: Any] {
            if let submenu = dict["sortFilterSubMenuRenderer"] as? [String: Any],
               let items = submenu["subMenuItems"] as? [[String: Any]]
            {
                let tokens = items.map { Self.firstString(forKey: "token", in: $0) }
                return (tokens.first ?? nil, tokens.count > 1 ? tokens[1] : nil)
            }
            for nested in dict.values {
                let found = Self.sortTokens(of: nested)
                if found.top != nil || found.newest != nil { return found }
            }
        } else if let array = value as? [Any] {
            for element in array {
                let found = Self.sortTokens(of: element)
                if found.top != nil || found.newest != nil { return found }
            }
        }
        return (nil, nil)
    }

    // MARK: - Entity Payloads (2024+ format)

    private static func commentsFromEntityPayloads(_ data: [String: Any]) -> [YouTubeComment] {
        let updates = data["frameworkUpdates"] as? [String: Any]
        let batch = updates?["entityBatchUpdate"] as? [String: Any]
        let mutations = batch?["mutations"] as? [[String: Any]] ?? []

        // Entity payloads are flat; the thread structure and ordering come
        // from the comment view models in the continuation items. Each view
        // model references its comment, engagement-toolbar surface (like/dislike
        // commands), and engagement-toolbar STATE (the creator-heart flag) via
        // separate keys: `commentKey`, `toolbarSurfaceKey`, `toolbarStateKey`.
        var commentsByKey: [String: [String: Any]] = [:]
        var orderedPayloads: [[String: Any]] = []
        var surfacesByKey: [String: ToolbarSurface] = [:]
        var heartedStateKeys: Set<String> = []

        for mutation in mutations {
            guard let payload = mutation["payload"] as? [String: Any] else { continue }
            let key = mutation["entityKey"] as? String
            if let comment = payload["commentEntityPayload"] as? [String: Any] {
                orderedPayloads.append(comment)
                if let key {
                    commentsByKey[key] = comment
                }
            }
            // The creator-heart flag lives on the engagement-toolbar STATE
            // payload as `heartState` ("TOOLBAR_HEART_STATE_HEARTED" when the
            // creator hearted the comment), keyed by `toolbarStateKey`.
            if let key,
               let state = payload["engagementToolbarStateEntityPayload"] as? [String: Any],
               (state["heartState"] as? String) == "TOOLBAR_HEART_STATE_HEARTED"
            {
                heartedStateKeys.insert(key)
            }
            // The engagement-toolbar SURFACE payload carries the like/dislike
            // commands, keyed by `toolbarSurfaceKey`.
            if let key,
               let surface = payload["engagementToolbarSurfaceEntityPayload"] as? [String: Any]
            {
                surfacesByKey[key] = ToolbarSurface(
                    like: Self.actionToken(of: surface["likeCommand"]),
                    unlike: Self.actionToken(of: surface["unlikeCommand"]),
                    dislike: Self.actionToken(of: surface["dislikeCommand"]),
                    undislike: Self.actionToken(of: surface["undislikeCommand"])
                )
            }
        }

        // Preferred path: walk the view models for order, thread replies,
        // and the toolbar-surface linkage.
        var viewModels: [(vm: [String: Any], replies: String?, isPinned: Bool)] = []
        Self.collectCommentViewModels(in: data, into: &viewModels)

        if !viewModels.isEmpty {
            return viewModels.compactMap { entry in
                guard let commentKey = entry.vm["commentKey"] as? String,
                      let payload = commentsByKey[commentKey],
                      var comment = Self.comment(fromEntityPayload: payload)
                else {
                    return nil
                }
                if let surfaceKey = entry.vm["toolbarSurfaceKey"] as? String,
                   let surface = surfacesByKey[surfaceKey]
                {
                    comment.likeAction = surface.like
                    comment.unlikeAction = surface.unlike
                    comment.dislikeAction = surface.dislike
                    comment.undislikeAction = surface.undislike
                }
                // Creator heart: the STATE payload (via `toolbarStateKey`) says
                // whether the comment is hearted; the hearting-channel avatar is
                // the `toolbar.creatorThumbnailUrl` on the comment payload, which
                // YouTube only sends for hearted comments.
                if let stateKey = entry.vm["toolbarStateKey"] as? String,
                   heartedStateKeys.contains(stateKey)
                {
                    comment.isHeartedByCreator = true
                    comment.creatorHeartAvatarURL = Self.creatorHeartAvatarURL(inPayload: payload)
                }
                comment.repliesContinuation = entry.replies
                comment.isPinned = entry.isPinned
                return comment
            }
        }

        // Fallback: mutation order without thread/action linkage.
        return orderedPayloads.compactMap { Self.comment(fromEntityPayload: $0) }
    }

    /// The hearting-channel avatar for a hearted comment: the entity payload's
    /// `toolbar.creatorThumbnailUrl` (present only when the comment is hearted).
    private static func creatorHeartAvatarURL(inPayload payload: [String: Any]) -> URL? {
        let toolbar = payload["toolbar"] as? [String: Any]
        return (toolbar?["creatorThumbnailUrl"] as? String).flatMap(URL.init(string:))
    }

    /// Extracts the `performCommentActionEndpoint.action` token from a
    /// toolbar command container.
    private static func actionToken(of command: Any?) -> String? {
        guard let command else { return nil }
        return Self.firstString(forKey: "action", in: command)
    }

    /// Collects comment view models in display order, with each thread's
    /// replies continuation. Handles top-level threads
    /// (`commentThreadRenderer`) and bare view models (reply pages).
    private static func collectCommentViewModels(
        in value: Any,
        into results: inout [(vm: [String: Any], replies: String?, isPinned: Bool)]
    ) {
        if let dict = value as? [String: Any] {
            if let thread = dict["commentThreadRenderer"] as? [String: Any] {
                if let viewModel = innerCommentViewModel(of: thread["commentViewModel"]) {
                    let repliesToken = (thread["replies"] as? [String: Any])
                        .flatMap { Self.firstString(forKey: "token", in: $0) }
                    results.append((viewModel, repliesToken, Self.isPinned(viewModel: viewModel)))
                }
                return
            }

            if let viewModel = Self.innerCommentViewModel(of: dict["commentViewModel"]) {
                results.append((viewModel, nil, Self.isPinned(viewModel: viewModel)))
                return
            }

            for nested in dict.values {
                Self.collectCommentViewModels(in: nested, into: &results)
            }
        } else if let array = value as? [Any] {
            for element in array {
                Self.collectCommentViewModels(in: element, into: &results)
            }
        }
    }

    /// Whether the comment view model marks the comment as pinned. YouTube
    /// exposes this as a `pinnedText` run ("Pinned by …") on the view model or a
    /// nested `pinnedCommentBadge`.
    private static func isPinned(viewModel: [String: Any]) -> Bool {
        if viewModel["pinnedText"] != nil { return true }
        if viewModel["pinnedCommentBadge"] != nil { return true }
        return false
    }

    /// `commentViewModel` sometimes wraps another `commentViewModel` level.
    private static func innerCommentViewModel(of value: Any?) -> [String: Any]? {
        guard let dict = value as? [String: Any] else { return nil }
        if let inner = dict["commentViewModel"] as? [String: Any] {
            return inner["commentKey"] != nil ? inner : nil
        }
        return dict["commentKey"] != nil ? dict : nil
    }

    private static func comment(fromEntityPayload payload: [String: Any]) -> YouTubeComment? {
        let properties = payload["properties"] as? [String: Any]
        let author = payload["author"] as? [String: Any]

        guard let commentId = properties?["commentId"] as? String,
              let text = (properties?["content"] as? [String: Any])?["content"] as? String,
              let authorName = author?["displayName"] as? String
        else {
            return nil
        }

        let toolbar = payload["toolbar"] as? [String: Any]

        // Author badges. `isVerified`/`isArtist` mark the checkmark; `isCreator`
        // flags the video's own creator. (Confirmed against live data: e.g.
        // MrBeast's own comment carries `author.isVerified` and `author.isCreator`.)
        let isVerified = (author?["isVerified"] as? Bool ?? false)
            || (author?["isArtist"] as? Bool ?? false)
        let isChannelOwner = author?["isCreator"] as? Bool ?? false

        // Membership (sponsor) badge: a channel member's custom badge icon URL
        // plus an accessibility tooltip (e.g. "Member (6 months)"). In the modern
        // entity format these are `author.sponsorBadgeUrl` / `author.sponsorBadgeA11y`.
        let memberBadgeURL = (author?["sponsorBadgeUrl"] as? String).flatMap(URL.init(string:))
        let memberTooltip = author?["sponsorBadgeA11y"] as? String

        return YouTubeComment(
            id: commentId,
            author: authorName,
            authorAvatarURL: (author?["avatarThumbnailUrl"] as? String).flatMap(URL.init(string:)),
            text: text,
            publishedText: properties?["publishedTime"] as? String,
            likeCountText: toolbar?["likeCountNotliked"] as? String,
            authorChannelId: author?["channelId"] as? String,
            authorIsVerified: isVerified,
            authorIsChannelOwner: isChannelOwner,
            memberBadgeThumbnailURL: memberBadgeURL,
            memberBadgeTooltip: memberTooltip
        )
    }

    // MARK: - Legacy Renderers

    private static func commentsFromLegacyRenderers(_ data: [String: Any]) -> [YouTubeComment] {
        var comments: [YouTubeComment] = []
        Self.collectLegacy(in: data, into: &comments)
        return comments
    }

    private static func collectLegacy(in value: Any, into comments: inout [YouTubeComment]) {
        if let dict = value as? [String: Any] {
            if let renderer = dict["commentRenderer"] as? [String: Any] {
                if let comment = comment(fromLegacyRenderer: renderer) {
                    comments.append(comment)
                }
                return
            }
            for nested in dict.values {
                Self.collectLegacy(in: nested, into: &comments)
            }
        } else if let array = value as? [Any] {
            for element in array {
                Self.collectLegacy(in: element, into: &comments)
            }
        }
    }

    private static func comment(fromLegacyRenderer renderer: [String: Any]) -> YouTubeComment? {
        guard let commentId = renderer["commentId"] as? String,
              let text = YouTubeItemParser.text(from: renderer["contentText"]),
              let author = YouTubeItemParser.text(from: renderer["authorText"])
        else {
            return nil
        }

        // Verified badge: an `authorCommentBadge` with a CHECK/verified icon.
        let isVerified = Self.legacyIsVerified(renderer["authorCommentBadge"])
        let isChannelOwner = renderer["authorIsChannelOwner"] as? Bool ?? false

        // Membership (sponsor) badge: a custom icon thumbnail plus a tooltip.
        let sponsorBadge = renderer["sponsorCommentBadge"] as? [String: Any]
        let sponsorRenderer = sponsorBadge?["sponsorCommentBadgeRenderer"] as? [String: Any]
        let memberBadgeURL = YouTubeItemParser.thumbnailURL(
            fromThumbnail: sponsorRenderer?["customBadge"] ?? sponsorRenderer?["icon"]
        )
        let memberTooltip = (sponsorRenderer?["tooltip"] as? String)
            ?? sponsorBadge.flatMap { Self.firstString(forKey: "tooltip", in: $0) }

        // Creator heart: presence of `creatorHeart` and the hearting avatar.
        let heartRenderer = (renderer["actionButtons"] as? [String: Any])
            .flatMap { ($0["commentActionButtonsRenderer"] as? [String: Any])?["creatorHeart"] }
        let heart = (heartRenderer as? [String: Any])?["creatorHeartRenderer"] as? [String: Any]
        let isHearted = heart != nil
        let heartAvatar = YouTubeItemParser.thumbnailURL(fromThumbnail: heart?["creatorThumbnail"])

        let isPinned = renderer["pinnedCommentBadge"] != nil

        return YouTubeComment(
            id: commentId,
            author: author,
            authorAvatarURL: YouTubeItemParser.thumbnailURL(fromThumbnail: renderer["authorThumbnail"]),
            text: text,
            publishedText: YouTubeItemParser.text(from: renderer["publishedTimeText"]),
            likeCountText: YouTubeItemParser.text(from: renderer["voteCount"]),
            authorIsVerified: isVerified,
            authorIsChannelOwner: isChannelOwner,
            memberBadgeThumbnailURL: memberBadgeURL,
            memberBadgeTooltip: memberTooltip,
            isHeartedByCreator: isHearted,
            creatorHeartAvatarURL: heartAvatar,
            isPinned: isPinned
        )
    }

    /// Whether a legacy `authorCommentBadge` is a verified/artist checkmark
    /// (its icon type contains CHECK), as opposed to a membership badge.
    private static func legacyIsVerified(_ value: Any?) -> Bool {
        guard let badge = value as? [String: Any],
              let renderer = badge["authorCommentBadgeRenderer"] as? [String: Any]
        else {
            return false
        }
        if let iconType = Self.firstString(forKey: "iconType", in: renderer) {
            return iconType.contains("CHECK") || iconType.contains("VERIFIED")
        }
        return false
    }

    // MARK: - Continuation & Create Params

    /// The next comments page token: the last continuation among the
    /// appended items (reply continuations come earlier within threads).
    private static func nextPageToken(of data: [String: Any]) -> String? {
        let endpoints = data["onResponseReceivedEndpoints"] as? [[String: Any]]
            ?? data["onResponseReceivedActions"] as? [[String: Any]]
            ?? []

        var token: String?
        for endpoint in endpoints {
            let items = (endpoint["appendContinuationItemsAction"] as? [String: Any])?["continuationItems"]
                as? [[String: Any]]
                ?? (endpoint["reloadContinuationItemsCommand"] as? [String: Any])?["continuationItems"]
                as? [[String: Any]]
                ?? []
            for item in items {
                if let continuationItem = item["continuationItemRenderer"] as? [String: Any],
                   let found = YouTubeFeedParser.token(fromContinuationItem: continuationItem)
                {
                    token = found
                }
            }
        }
        return token
    }

    /// Depth-first search for a string value under the given key.
    static func firstString(forKey key: String, in value: Any) -> String? {
        if let dict = value as? [String: Any] {
            if let match = dict[key] as? String {
                return match
            }
            for nested in dict.values {
                if let found = Self.firstString(forKey: key, in: nested) {
                    return found
                }
            }
        } else if let array = value as? [Any] {
            for element in array {
                if let found = Self.firstString(forKey: key, in: element) {
                    return found
                }
            }
        }
        return nil
    }
}
