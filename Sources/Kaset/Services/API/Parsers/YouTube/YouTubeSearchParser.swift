import Foundation

/// Parses YouTube `search` responses.
///
/// June 2026 renderer mix (confirmed via api-explorer):
/// - Videos: legacy `videoRenderer`
/// - Channels: legacy `channelRenderer`
/// - Playlists: new `lockupViewModel` (`LOCKUP_CONTENT_TYPE_PLAYLIST`)
/// - Shorts shelves: `shortsLockupViewModel` (intentionally skipped)
enum YouTubeSearchParser {
    /// Parses a full search response.
    static func parse(_ data: [String: Any]) -> YouTubeSearchResponse {
        var response = YouTubeSearchResponse.empty

        let sections = Self.primarySections(of: data)
        for section in sections {
            if let itemSection = section["itemSectionRenderer"] as? [String: Any],
               let items = itemSection["contents"] as? [[String: Any]]
            {
                for item in items {
                    Self.append(item, to: &response)
                }
            } else if response.continuation == nil,
                      let continuationItem = section["continuationItemRenderer"] as? [String: Any]
            {
                response.continuation = YouTubeFeedParser.token(
                    fromContinuationItem: continuationItem
                )
            }
        }

        response.filterGroups = Self.filterGroups(of: data)
        return response
    }

    // MARK: - Filters

    /// Parses the search filter groups (Type, Upload date, Duration, Features,
    /// Sort by) from the "Filters" dialog in the search header. Each option
    /// carries the opaque `searchEndpoint.params` to re-run the search with it
    /// applied. Found via a scoped recursive walk since YouTube has moved this
    /// between `subMenu` and the header filter button across layouts.
    static func filterGroups(of data: [String: Any]) -> [YouTubeSearchFilterGroup] {
        var renderers: [[String: Any]] = []
        Self.collectFilterGroupRenderers(in: data["header"] ?? data, into: &renderers)
        return renderers.compactMap(Self.filterGroup(from:))
    }

    private static func collectFilterGroupRenderers(in value: Any, into out: inout [[String: Any]]) {
        if let dict = value as? [String: Any] {
            if let renderer = dict["searchFilterGroupRenderer"] as? [String: Any] {
                out.append(renderer)
            }
            for nested in dict.values {
                Self.collectFilterGroupRenderers(in: nested, into: &out)
            }
        } else if let array = value as? [Any] {
            for element in array {
                Self.collectFilterGroupRenderers(in: element, into: &out)
            }
        }
    }

    private static func filterGroup(from renderer: [String: Any]) -> YouTubeSearchFilterGroup? {
        guard let title = YouTubeItemParser.text(from: renderer["title"]),
              let filters = renderer["filters"] as? [[String: Any]]
        else {
            return nil
        }

        let options: [YouTubeSearchFilterGroup.Option] = filters.compactMap { filter in
            guard let inner = filter["searchFilterRenderer"] as? [String: Any],
                  let label = YouTubeItemParser.text(from: inner["label"])
            else {
                return nil
            }
            let params = ((inner["navigationEndpoint"] as? [String: Any])?["searchEndpoint"]
                as? [String: Any])?["params"] as? String
            let status = inner["status"] as? String
            return YouTubeSearchFilterGroup.Option(
                label: label,
                params: params,
                isSelected: status == "FILTER_STATUS_SELECTED",
                isDisabled: status == "FILTER_STATUS_DISABLED"
            )
        }

        guard !options.isEmpty else { return nil }
        return YouTubeSearchFilterGroup(title: title, options: options)
    }

    /// Parses a search continuation response.
    static func parseContinuation(_ data: [String: Any]) -> YouTubeSearchResponse {
        var response = YouTubeSearchResponse.empty
        let actions = data["onResponseReceivedCommands"] as? [[String: Any]]
            ?? data["onResponseReceivedActions"] as? [[String: Any]]
            ?? []

        for action in actions {
            let items = (action["appendContinuationItemsAction"] as? [String: Any])?["continuationItems"]
                as? [[String: Any]] ?? []
            for sectionItem in items {
                if let itemSection = sectionItem["itemSectionRenderer"] as? [String: Any],
                   let items = itemSection["contents"] as? [[String: Any]]
                {
                    for item in items {
                        Self.append(item, to: &response)
                    }
                } else if response.continuation == nil,
                          let continuationItem = sectionItem["continuationItemRenderer"]
                          as? [String: Any]
                {
                    response.continuation = YouTubeFeedParser.token(
                        fromContinuationItem: continuationItem
                    )
                }
            }
        }

        return response
    }

    // MARK: - Private

    /// The primary result sections
    /// (`contents.twoColumnSearchResultsRenderer.primaryContents.sectionListRenderer.contents`).
    private static func primarySections(of data: [String: Any]) -> [[String: Any]] {
        let sectionList = (
            (
                (data["contents"] as? [String: Any])?["twoColumnSearchResultsRenderer"]
                    as? [String: Any]
            )?["primaryContents"] as? [String: Any]
        )?["sectionListRenderer"] as? [String: Any]
        return sectionList?["contents"] as? [[String: Any]] ?? []
    }

    /// Dispatches one result item into the right bucket, preserving order in
    /// `items` so the UI can render YouTube's original interleaving.
    private static func append(_ item: [String: Any], to response: inout YouTubeSearchResponse) {
        if let video = YouTubeItemParser.video(fromAnyItem: item) {
            response.videos.append(video)
            response.items.append(.video(video))
            return
        }

        if let channelRenderer = item["channelRenderer"] as? [String: Any],
           let channel = YouTubeItemParser.channel(fromChannelRenderer: channelRenderer)
        {
            response.channels.append(channel)
            response.items.append(.channel(channel))
            return
        }

        if let lockup = item["lockupViewModel"] as? [String: Any],
           let playlist = YouTubeItemParser.playlist(fromLockup: lockup)
        {
            response.playlists.append(playlist)
            response.items.append(.playlist(playlist))
        }
    }
}
