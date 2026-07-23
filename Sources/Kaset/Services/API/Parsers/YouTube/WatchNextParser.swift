import Foundation

/// Parses YouTube `next` (watch-next) responses: primary video metadata
/// plus the related-videos rail.
enum WatchNextParser {
    static func parse(_ data: [String: Any]) -> WatchNextData {
        let results = (data["contents"] as? [String: Any])?["twoColumnWatchNextResults"]
            as? [String: Any]

        // Primary metadata (title, view count, channel)
        var videoTitle: String?
        var viewCountText: String?
        var publishedText: String?
        var channel: YouTubeChannel?
        var isSubscribed: Bool?
        var notificationPreference: ChannelNotificationPreference?
        var secondaryDescriptionText: String?
        var ownerRenderer: [String: Any]?

        let primaryContents = (
            (results?["results"] as? [String: Any])?["results"] as? [String: Any]
        )?["contents"] as? [[String: Any]] ?? []

        for content in primaryContents {
            if let primaryInfo = content["videoPrimaryInfoRenderer"] as? [String: Any] {
                videoTitle = YouTubeItemParser.text(from: primaryInfo["title"])
                publishedText = YouTubeItemParser.text(from: primaryInfo["relativeDateText"])
                let viewCount = (primaryInfo["viewCount"] as? [String: Any])?["videoViewCountRenderer"]
                    as? [String: Any]
                viewCountText = YouTubeItemParser.text(from: viewCount?["viewCount"])
            }

            if let secondaryInfo = content["videoSecondaryInfoRenderer"] as? [String: Any] {
                if let content = (secondaryInfo["attributedDescription"] as? [String: Any])?["content"]
                    as? String, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    secondaryDescriptionText = content
                }
                if let owner = (secondaryInfo["owner"] as? [String: Any])?["videoOwnerRenderer"]
                    as? [String: Any]
                {
                    ownerRenderer = owner
                    channel = Self.channel(fromVideoOwner: owner)
                }
                if let subscribeButton = (secondaryInfo["subscribeButton"] as? [String: Any])?["subscribeButtonRenderer"]
                    as? [String: Any]
                {
                    isSubscribed = subscribeButton["subscribed"] as? Bool
                    notificationPreference = Self.notificationPreference(from: subscribeButton)
                }
            }
        }

        // Related videos rail
        var related: [YouTubeVideo] = []
        var continuation: String?
        if let secondaryResults = results?["secondaryResults"] {
            YouTubeFeedParser.collect(
                in: secondaryResults,
                videos: &related,
                continuation: &continuation
            )
        }

        let chapters = Self.chapters(of: data)

        // Collaboration uploads: the classic single-owner parse is empty; the
        // credited channels live in the owner's "Collaborators" picker instead.
        let collaborators = ownerRenderer.map {
            Self.collaborators(fromVideoOwner: $0, subscribedByKey: Self.subscriptionStates(in: data))
        } ?? []

        return WatchNextData(
            videoTitle: videoTitle,
            viewCountText: viewCountText,
            publishedText: publishedText,
            channel: channel,
            related: YouTubeFeedParser.deduplicate(related),
            chapters: chapters,
            heatmap: Self.heatmap(of: data),
            descriptionText: Self.descriptionText(of: data) ?? secondaryDescriptionText,
            isSubscribed: isSubscribed,
            commentsContinuation: Self.commentsContinuation(of: data),
            liveChatContinuation: Self.liveChatContinuation(of: data),
            notificationPreference: notificationPreference,
            collaborators: collaborators
        )
    }

    // MARK: - Collaboration Owners

    /// Parses the credited channels on a collaboration upload from the owner's
    /// "Collaborators" dialog (`videoOwnerRenderer.navigationEndpoint`). Each
    /// collaborator's Subscribe/bell menu comes straight from YouTube's
    /// `subscribeButtonViewModel`, so acting on it just replays YouTube's own
    /// endpoints. Returns `[]` for ordinary single-owner videos.
    static func collaborators(
        fromVideoOwner owner: [String: Any],
        subscribedByKey: [String: Bool]
    ) -> [VideoCollaborator] {
        let dialog = ((((owner["navigationEndpoint"] as? [String: Any])?["showDialogCommand"]
            as? [String: Any])?["panelLoadingStrategy"] as? [String: Any])?["inlineContent"]
            as? [String: Any])?["dialogViewModel"] as? [String: Any]
        let items = (((dialog?["customContent"] as? [String: Any])?["listViewModel"]
            as? [String: Any])?["listItems"] as? [[String: Any]]) ?? []

        return items.compactMap { item in
            Self.collaborator(
                fromListItem: item["listItemViewModel"] as? [String: Any],
                subscribedByKey: subscribedByKey
            )
        }
    }

    private static func collaborator(
        fromListItem item: [String: Any]?,
        subscribedByKey: [String: Bool]
    ) -> VideoCollaborator? {
        guard let item,
              let title = item["title"] as? [String: Any],
              let name = title["content"] as? String,
              let subscribe = ((item["trailingButtons"] as? [String: Any])?["buttons"]
                  as? [[String: Any]])?.first?["subscribeButtonViewModel"] as? [String: Any],
              let channelId = subscribe["channelId"] as? String
        else {
            return nil
        }

        let subtitle = (item["subtitle"] as? [String: Any])?["content"] as? String
        let (handle, subscriberText) = Self.splitCollaboratorSubtitle(subtitle)
        let avatarURL = Self.avatarURL(fromAccessory: item["leadingAccessory"])

        let subscribed = (subscribe["stateEntityStoreKey"] as? String)
            .flatMap { subscribedByKey[$0] } ?? false

        return VideoCollaborator(
            channelId: channelId,
            name: name,
            isVerified: Self.containsImageName(title["attachmentRuns"], "CHECK_CIRCLE_FILLED"),
            handle: handle,
            subscriberText: subscriberText,
            avatarURL: avatarURL,
            isSubscribed: subscribed,
            notification: Self.notificationPreference(
                fromSubscribeButtonViewModel: subscribe,
                channelId: channelId
            )
        )
    }

    /// The bell menu from the newer `subscribeButtonViewModel.onShowSubscriptionOptions`
    /// sheet (used by collaboration owners), mapped onto the same
    /// `ChannelNotificationPreference` the classic single-owner bell uses.
    private static func notificationPreference(
        fromSubscribeButtonViewModel subscribe: [String: Any],
        channelId: String
    ) -> ChannelNotificationPreference? {
        guard subscribe["disableNotificationBell"] as? Bool != true else { return nil }

        let sheetItems = ((((((subscribe["onShowSubscriptionOptions"] as? [String: Any])?[
            "innertubeCommand"
        ] as? [String: Any])?["showSheetCommand"] as? [String: Any])?["panelLoadingStrategy"]
            as? [String: Any])?["inlineContent"] as? [String: Any])?["sheetViewModel"]
            as? [String: Any]).flatMap { sheet in
            (((sheet["content"] as? [String: Any])?["listViewModel"] as? [String: Any])?[
                "listItems"
            ] as? [[String: Any]])
        } ?? []

        var options: [ChannelNotificationPreference.Option] = []
        var unsubscribeLabel = String(localized: "Unsubscribe")

        for sheetItem in sheetItems {
            guard let option = sheetItem["listItemViewModel"] as? [String: Any] else { continue }
            let iconType = Self.firstImageName(option["leadingImage"]) ?? ""
            let label = (option["title"] as? [String: Any])?["content"] as? String ?? ""
            let command = (((option["rendererContext"] as? [String: Any])?["commandContext"]
                as? [String: Any])?["onTap"] as? [String: Any])?["innertubeCommand"] as? [String: Any]

            // The unsubscribe row (PERSON_MINUS) uses a different endpoint; keep
            // its localized label but drive unsubscribe through `setSubscribed`.
            guard let params = (command?["modifyChannelNotificationPreferenceEndpoint"]
                as? [String: Any])?["params"] as? String
            else {
                if iconType == "PERSON_MINUS", !label.isEmpty { unsubscribeLabel = label }
                continue
            }

            options.append(ChannelNotificationPreference.Option(
                level: .init(iconType: iconType),
                label: label,
                params: params,
                isCurrent: option["isSelected"] as? Bool ?? false
            ))
        }

        guard !options.isEmpty else { return nil }
        return ChannelNotificationPreference(
            channelId: channelId,
            options: options,
            unsubscribeLabel: unsubscribeLabel
        )
    }

    /// Subscribed states keyed by `subscribeButtonViewModel.stateEntityStoreKey`,
    /// read from the `frameworkUpdates` entity store (the canonical live state).
    private static func subscriptionStates(in data: [String: Any]) -> [String: Bool] {
        var result: [String: Bool] = [:]
        Self.collectSubscriptionStates(in: data, into: &result)
        return result
    }

    private static func collectSubscriptionStates(in value: Any, into result: inout [String: Bool]) {
        if let dict = value as? [String: Any] {
            if let entity = dict["subscriptionStateEntity"] as? [String: Any],
               let key = entity["key"] as? String,
               let subscribed = entity["subscribed"] as? Bool
            {
                result[key] = subscribed
            }
            for nested in dict.values {
                Self.collectSubscriptionStates(in: nested, into: &result)
            }
        } else if let array = value as? [Any] {
            for element in array {
                Self.collectSubscriptionStates(in: element, into: &result)
            }
        }
    }

    /// Splits YouTube's collaborator subtitle ("@handle • 246K subscribers") into
    /// its handle and subscriber-count parts, stripping the bidi isolate control
    /// characters YouTube wraps each run in.
    private static func splitCollaboratorSubtitle(_ subtitle: String?) -> (handle: String?, subscribers: String?) {
        guard let subtitle else { return (nil, nil) }
        let cleaned = subtitle.filter { !$0.unicodeScalars.contains { (0x2066 ... 0x2069).contains($0.value) || $0.value == 0x200E } }
        let parts = cleaned.split(separator: "•", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let handle = parts.first { $0.hasPrefix("@") }
        let subscribers = parts.first { !$0.hasPrefix("@") && !$0.isEmpty }
        return (handle?.isEmpty == false ? handle : nil, subscribers)
    }

    private static func avatarURL(fromAccessory accessory: Any?) -> URL? {
        guard let sources = (((accessory as? [String: Any])?["avatarViewModel"] as? [String: Any])?[
            "image"
        ] as? [String: Any])?["sources"] as? [[String: Any]],
            let urlString = sources.first?["url"] as? String
        else {
            return nil
        }
        return URL(string: urlString)
    }

    /// The first `clientResource.imageName` under a viewModel image node.
    private static func firstImageName(_ value: Any?) -> String? {
        guard let sources = (value as? [String: Any])?["sources"] as? [[String: Any]] else {
            return nil
        }
        return sources.compactMap { ($0["clientResource"] as? [String: Any])?["imageName"] as? String }.first
    }

    /// Whether the given attributed-text runs contain a specific icon (used to
    /// detect the verified `CHECK_CIRCLE_FILLED` badge on a channel name).
    private static func containsImageName(_ value: Any?, _ imageName: String) -> Bool {
        if let dict = value as? [String: Any] {
            if (dict["imageName"] as? String) == imageName { return true }
            return dict.values.contains { Self.containsImageName($0, imageName) }
        }
        if let array = value as? [Any] {
            return array.contains { Self.containsImageName($0, imageName) }
        }
        return false
    }

    /// Extracts the subscription notification "bell" menu from a
    /// `subscribeButtonRenderer` — the options + their apply-`params` come
    /// straight from YouTube's `notificationPreferenceButton` popup menu.
    static func notificationPreference(from subscribeButton: [String: Any]) -> ChannelNotificationPreference? {
        guard let channelId = subscribeButton["channelId"] as? String,
              let toggle = (subscribeButton["notificationPreferenceButton"] as? [String: Any])?[
                  "subscriptionNotificationToggleButtonRenderer"
              ] as? [String: Any]
        else { return nil }

        let commands = ((toggle["command"] as? [String: Any])?["commandExecutorCommand"] as? [String: Any])?[
            "commands"
        ] as? [[String: Any]] ?? []

        var menuItems: [[String: Any]] = []
        for command in commands {
            if let items = (((command["openPopupAction"] as? [String: Any])?["popup"] as? [String: Any])?[
                "menuPopupRenderer"
            ] as? [String: Any])?["items"] as? [[String: Any]] {
                menuItems = items
                break
            }
        }

        let options: [ChannelNotificationPreference.Option] = menuItems.compactMap { item in
            guard let renderer = item["menuServiceItemRenderer"] as? [String: Any],
                  let params = ((renderer["serviceEndpoint"] as? [String: Any])?[
                      "modifyChannelNotificationPreferenceEndpoint"
                  ] as? [String: Any])?["params"] as? String
            else { return nil }
            let label = (renderer["text"] as? [String: Any])?["simpleText"] as? String ?? ""
            let iconType = (renderer["icon"] as? [String: Any])?["iconType"] as? String ?? ""
            return ChannelNotificationPreference.Option(
                level: .init(iconType: iconType),
                label: label,
                params: params,
                isCurrent: renderer["isSelected"] as? Bool ?? false
            )
        }

        guard !options.isEmpty else { return nil }
        let unsubscribeLabel = YouTubeItemParser.text(from: subscribeButton["unsubscribeButtonText"])
            ?? String(localized: "Unsubscribe")
        return ChannelNotificationPreference(
            channelId: channelId,
            options: options,
            unsubscribeLabel: unsubscribeLabel
        )
    }

    /// Initial live-chat continuation token, present only for live streams (or
    /// premieres) with chat enabled: `conversationBar.liveChatRenderer`.
    static func liveChatContinuation(of data: [String: Any]) -> String? {
        let results = (data["contents"] as? [String: Any])?["twoColumnWatchNextResults"] as? [String: Any]
        let renderer = (results?["conversationBar"] as? [String: Any])?["liveChatRenderer"] as? [String: Any]
        let continuations = renderer?["continuations"] as? [[String: Any]] ?? []
        for continuation in continuations {
            if let reload = continuation["reloadContinuationData"] as? [String: Any],
               let token = reload["continuation"] as? String
            {
                return token
            }
        }
        return nil
    }

    /// "Most replayed" heatmap samples, exposed via a `macroMarkersListEntity`
    /// of type `MARKER_TYPE_HEATMAP` inside `frameworkUpdates`. Each sample is a
    /// normalized position (start / total span) and its replay intensity (0…1).
    static func heatmap(of data: [String: Any]) -> [YouTubeHeatmapMarker] {
        let videoId = self.currentVideoId(of: data)
        guard let markers = self.firstHeatmapMarkers(in: data, videoId: videoId),
              let last = markers.last,
              let lastStart = self.intValue(from: last["startMillis"]),
              let lastDuration = self.intValue(from: last["durationMillis"])
        else {
            return []
        }
        let span = Double(lastStart + lastDuration)
        guard span > 0 else { return [] }

        return markers.compactMap { marker in
            guard let start = self.intValue(from: marker["startMillis"]),
                  let intensity = marker["intensityScoreNormalized"] as? Double
            else {
                return nil
            }
            return YouTubeHeatmapMarker(
                fraction: min(max(Double(start) / span, 0), 1),
                intensity: min(max(intensity, 0), 1)
            )
        }
    }

    /// Recursively finds the first heatmap `macroMarkersListEntity` matching the
    /// current video, returning its raw marker dictionaries.
    private static func firstHeatmapMarkers(
        in value: Any,
        videoId: String?
    ) -> [[String: Any]]? {
        if let dict = value as? [String: Any] {
            if let entity = dict["macroMarkersListEntity"] as? [String: Any],
               let list = entity["markersList"] as? [String: Any],
               list["markerType"] as? String == "MARKER_TYPE_HEATMAP",
               let markers = list["markers"] as? [[String: Any]],
               !markers.isEmpty
            {
                let entityVideoId = entity["externalVideoId"] as? String
                if videoId == nil || entityVideoId == nil || entityVideoId == videoId {
                    return markers
                }
            }
            for nested in dict.values {
                if let found = self.firstHeatmapMarkers(in: nested, videoId: videoId) {
                    return found
                }
            }
        } else if let array = value as? [Any] {
            for element in array {
                if let found = self.firstHeatmapMarkers(in: element, videoId: videoId) {
                    return found
                }
            }
        }
        return nil
    }

    /// Navigation chapters exposed by YouTube's watch-next response.
    ///
    /// Prefer the player bar's `chapterRenderer` markers because they are the
    /// canonical watch-page timeline source. Fall back to
    /// `macroMarkersListItemRenderer`, which can appear in the chapters panel,
    /// structured description, and search previews, and therefore needs
    /// de-duplication.
    static func chapters(of data: [String: Any]) -> [YouTubeChapter] {
        let videoId = self.currentVideoId(of: data)
        var chapterRenderers: [YouTubeChapter] = []
        self.collectChapterRenderers(in: data, videoId: videoId, chapters: &chapterRenderers)
        let canonical = self.deduplicateChapters(chapterRenderers)

        var macroMarkers: [YouTubeChapter] = []
        self.collectMacroMarkerRenderers(in: data, fallbackVideoId: videoId, chapters: &macroMarkers)
        let deduplicatedMacroMarkers = self.deduplicateChapters(macroMarkers)
        guard !canonical.isEmpty else {
            return deduplicatedMacroMarkers
        }
        return self.mergingEndTimes(in: canonical, from: deduplicatedMacroMarkers)
    }

    /// Full watch-page description carried by the structured-description engagement panel.
    static func descriptionText(of data: [String: Any]) -> String? {
        guard let panels = data["engagementPanels"] as? [Any] else { return nil }
        return self.findDescriptionText(in: panels)
    }

    /// The continuation token for the watch page's comments section
    /// (the `comment-item-section` item section).
    static func commentsContinuation(of data: [String: Any]) -> String? {
        self.findCommentsSectionToken(in: data)
    }

    private static func findCommentsSectionToken(in value: Any) -> String? {
        if let dict = value as? [String: Any] {
            if let section = dict["itemSectionRenderer"] as? [String: Any],
               (section["sectionIdentifier"] as? String) == "comment-item-section"
            {
                return self.firstContinuationToken(in: section)
            }
            for nested in dict.values {
                if let token = Self.findCommentsSectionToken(in: nested) {
                    return token
                }
            }
        } else if let array = value as? [Any] {
            for element in array {
                if let token = Self.findCommentsSectionToken(in: element) {
                    return token
                }
            }
        }
        return nil
    }

    private static func findDescriptionText(in value: Any) -> String? {
        if let dict = value as? [String: Any] {
            if let attributed = dict["attributedDescriptionBodyText"] as? [String: Any],
               let content = attributed["content"] as? String,
               !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return content
            }
            if let descriptionBody = dict["descriptionBodyText"] as? [String: Any],
               let content = YouTubeItemParser.text(from: descriptionBody),
               !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return content
            }
            for nested in dict.values {
                if let description = self.findDescriptionText(in: nested) {
                    return description
                }
            }
        } else if let array = value as? [Any] {
            for element in array {
                if let description = self.findDescriptionText(in: element) {
                    return description
                }
            }
        }
        return nil
    }

    private static func firstContinuationToken(in value: Any) -> String? {
        if let dict = value as? [String: Any] {
            if let command = dict["continuationCommand"] as? [String: Any],
               let token = command["token"] as? String
            {
                return token
            }
            for nested in dict.values {
                if let token = Self.firstContinuationToken(in: nested) {
                    return token
                }
            }
        } else if let array = value as? [Any] {
            for element in array {
                if let token = Self.firstContinuationToken(in: element) {
                    return token
                }
            }
        }
        return nil
    }

    private static func currentVideoId(of data: [String: Any]) -> String? {
        if let endpoint = data["currentVideoEndpoint"] as? [String: Any],
           let watchEndpoint = endpoint["watchEndpoint"] as? [String: Any],
           let videoId = watchEndpoint["videoId"] as? String,
           !videoId.isEmpty
        {
            return videoId
        }

        return nil
    }

    private static func collectChapterRenderers(
        in value: Any,
        videoId: String?,
        chapters: inout [YouTubeChapter]
    ) {
        if let dict = value as? [String: Any] {
            if let renderer = dict["chapterRenderer"] as? [String: Any],
               let chapter = self.chapter(fromChapterRenderer: renderer, videoId: videoId)
            {
                chapters.append(chapter)
            }

            for nested in dict.values {
                self.collectChapterRenderers(in: nested, videoId: videoId, chapters: &chapters)
            }
        } else if let array = value as? [Any] {
            for element in array {
                self.collectChapterRenderers(in: element, videoId: videoId, chapters: &chapters)
            }
        }
    }

    private static func collectMacroMarkerRenderers(
        in value: Any,
        fallbackVideoId: String?,
        chapters: inout [YouTubeChapter]
    ) {
        if let dict = value as? [String: Any] {
            if let renderer = dict["macroMarkersListItemRenderer"] as? [String: Any],
               let chapter = self.chapter(fromMacroMarkerRenderer: renderer, fallbackVideoId: fallbackVideoId)
            {
                chapters.append(chapter)
            }

            for nested in dict.values {
                self.collectMacroMarkerRenderers(
                    in: nested,
                    fallbackVideoId: fallbackVideoId,
                    chapters: &chapters
                )
            }
        } else if let array = value as? [Any] {
            for element in array {
                self.collectMacroMarkerRenderers(
                    in: element,
                    fallbackVideoId: fallbackVideoId,
                    chapters: &chapters
                )
            }
        }
    }

    private static func chapter(
        fromChapterRenderer renderer: [String: Any],
        videoId: String?
    ) -> YouTubeChapter? {
        guard let title = YouTubeItemParser.text(from: renderer["title"]),
              let startMillis = self.intValue(from: renderer["timeRangeStartMillis"])
        else {
            return nil
        }

        return YouTubeChapter(
            videoId: videoId,
            title: title,
            startTime: TimeInterval(startMillis) / 1000,
            endTime: nil,
            timeText: nil,
            thumbnailURL: YouTubeItemParser.thumbnailURL(fromThumbnail: renderer["thumbnail"])
        )
    }

    private static func chapter(
        fromMacroMarkerRenderer renderer: [String: Any],
        fallbackVideoId: String?
    ) -> YouTubeChapter? {
        guard let title = YouTubeItemParser.text(from: renderer["title"]) else {
            return nil
        }

        let repeatCommand = self.findRepeatChapterCommand(in: renderer["repeatButton"])
        let watchEndpoint = self.watchEndpoint(from: renderer)
        let endpointVideoId = watchEndpoint?["videoId"] as? String
        if let fallbackVideoId, let endpointVideoId, endpointVideoId != fallbackVideoId {
            return nil
        }
        let timeText = YouTubeItemParser.text(from: renderer["timeDescription"])
        let startMillis = self.intValue(from: repeatCommand?["startTimeMs"])
            ?? self.intValue(from: watchEndpoint?["startTimeSeconds"]).map { $0 * 1000 }
            ?? timeText.flatMap(self.milliseconds(fromTimeText:))

        guard let startMillis else { return nil }

        return YouTubeChapter(
            videoId: endpointVideoId ?? fallbackVideoId,
            title: title,
            startTime: TimeInterval(startMillis) / 1000,
            endTime: self.intValue(from: repeatCommand?["endTimeMs"]).map { TimeInterval($0) / 1000 },
            timeText: timeText,
            thumbnailURL: YouTubeItemParser.thumbnailURL(fromThumbnail: renderer["thumbnail"])
        )
    }

    private static func milliseconds(fromTimeText text: String) -> Int? {
        let parts = text.split(separator: ":")
        guard parts.count == 2 || parts.count == 3 else {
            return nil
        }
        let values = parts.compactMap { Int($0) }
        guard values.count == parts.count else {
            return nil
        }

        let seconds: Int = if values.count == 3 {
            values[0] * 3600 + values[1] * 60 + values[2]
        } else {
            values[0] * 60 + values[1]
        }
        return seconds * 1000
    }

    private static func watchEndpoint(from renderer: [String: Any]) -> [String: Any]? {
        guard let onTap = renderer["onTap"] as? [String: Any] else { return nil }
        return onTap["watchEndpoint"] as? [String: Any]
    }

    private static func findRepeatChapterCommand(in value: Any?) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            if let command = dict["repeatChapterCommand"] as? [String: Any] {
                return command
            }

            for nested in dict.values {
                if let command = self.findRepeatChapterCommand(in: nested) {
                    return command
                }
            }
        } else if let array = value as? [Any] {
            for element in array {
                if let command = self.findRepeatChapterCommand(in: element) {
                    return command
                }
            }
        }

        return nil
    }

    private static func intValue(from value: Any?) -> Int? {
        switch value {
        case let int as Int:
            int
        case let double as Double:
            Int(double)
        case let number as NSNumber:
            Int(number.int64Value)
        case let string as String:
            Int(string)
        default:
            nil
        }
    }

    private static func deduplicateChapters(_ chapters: [YouTubeChapter]) -> [YouTubeChapter] {
        var indexByKey: [String: Int] = [:]
        var result: [YouTubeChapter] = []

        for chapter in chapters {
            let key = self.chapterKey(chapter)
            if let index = indexByKey[key] {
                if result[index].endTime == nil, chapter.endTime != nil {
                    result[index] = self.mergingEndTime(in: result[index], from: chapter)
                }
                continue
            }
            indexByKey[key] = result.count
            result.append(chapter)
        }

        return result.sorted { lhs, rhs in
            if lhs.startTime != rhs.startTime {
                return lhs.startTime < rhs.startTime
            }
            return lhs.title < rhs.title
        }
    }

    private static func mergingEndTimes(
        in chapters: [YouTubeChapter],
        from boundedChapters: [YouTubeChapter]
    ) -> [YouTubeChapter] {
        let boundsByKey = Dictionary(uniqueKeysWithValues: boundedChapters.map {
            (self.chapterKey($0), $0)
        })
        return chapters.map { chapter in
            guard chapter.endTime == nil, let boundedChapter = boundsByKey[self.chapterKey(chapter)] else {
                return chapter
            }
            return self.mergingEndTime(in: chapter, from: boundedChapter)
        }
    }

    private static func mergingEndTime(
        in chapter: YouTubeChapter,
        from boundedChapter: YouTubeChapter
    ) -> YouTubeChapter {
        YouTubeChapter(
            videoId: chapter.videoId,
            title: chapter.title,
            startTime: chapter.startTime,
            endTime: boundedChapter.endTime,
            timeText: chapter.timeText,
            thumbnailURL: chapter.thumbnailURL
        )
    }

    private static func chapterKey(_ chapter: YouTubeChapter) -> String {
        "\(chapter.videoId ?? "")|\(Int((chapter.startTime * 1000).rounded()))|\(chapter.title)"
    }

    // MARK: - Private

    private static func channel(fromVideoOwner owner: [String: Any]) -> YouTubeChannel? {
        let browseEndpoint = (owner["navigationEndpoint"] as? [String: Any])?["browseEndpoint"]
            as? [String: Any]
        guard let name = YouTubeItemParser.text(from: owner["title"]),
              let channelId = browseEndpoint?["browseId"] as? String
        else {
            return nil
        }

        return YouTubeChannel(
            channelId: channelId,
            name: name,
            handle: (browseEndpoint?["canonicalBaseUrl"] as? String)?
                .split(separator: "/").last.map(String.init),
            subscriberCountText: YouTubeItemParser.text(from: owner["subscriberCountText"]),
            thumbnailURL: YouTubeItemParser.thumbnailURL(fromThumbnail: owner["thumbnail"])
        )
    }
}
