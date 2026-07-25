import Foundation

// MARK: - WhatsNewProvider

/// Provides "What's New" entries from GitHub release notes, with a static fallback.
enum WhatsNewProvider {
    /// GitHub repo for fetching release notes.
    private static let owner = "Yoddikko"
    private static let repo = "kasetPlus"

    /// Static fallback entries used when the network is unavailable.
    static let fallbackCollection: [WhatsNew] = [
        WhatsNew(
            version: "0.12.0",
            title: "What's New in KasetPlus",
            features: [
                .init(
                    icon: "shield.lefthalf.filled",
                    title: "Built-in Ad Blocker",
                    subtitle: "API-level ad prevention + YouTube ad auto-skip"
                ),
                .init(
                    icon: "forward.end.fill",
                    title: "SponsorBlock",
                    subtitle: "Auto-skip sponsored segments with localized toast"
                ),
                .init(
                    icon: "hand.thumbsdown.fill",
                    title: "Return YouTube Dislikes",
                    subtitle: "Community dislike counts via RYD API"
                ),
                .init(
                    icon: "arrow.triangle.swap",
                    title: "DeArrow",
                    subtitle: "Clickbait-free titles from the DeArrow community"
                ),
                .init(
                    icon: "arrow.down.circle",
                    title: "Video Download",
                    subtitle: "Quality picker + MP3 via bundled yt-dlp"
                ),
            ],
            learnMoreURL: URL(string: "https://github.com/Yoddikko/kasetPlus/releases")
        ),
    ]

    // MARK: - Fetch from GitHub

    /// Fetches release notes pinned to the current app version from GitHub.
    /// Falls back only to a static entry for that exact version.
    static func fetchWhatsNew(
        for currentVersion: WhatsNew.Version = .current(),
        store: WhatsNewVersionStore = WhatsNewVersionStore(),
        respectingPresentedVersions: Bool = true,
        session: URLSession = .shared
    ) async -> WhatsNew? {
        if respectingPresentedVersions, store.hasPresented(currentVersion) {
            return nil
        }

        // Try fetching from GitHub releases
        if let dynamic = await fetchFromGitHub(for: currentVersion, session: session) {
            return dynamic
        }

        // Fall back to static collection
        return Self.staticWhatsNew(
            for: currentVersion,
            store: store,
            respectingPresentedVersions: respectingPresentedVersions
        )
    }

    /// Version-gating against the static fallback collection (synchronous).
    static func staticWhatsNew(
        for currentVersion: WhatsNew.Version = .current(),
        store: WhatsNewVersionStore = WhatsNewVersionStore(),
        respectingPresentedVersions: Bool = true
    ) -> WhatsNew? {
        if respectingPresentedVersions, store.hasPresented(currentVersion) {
            return nil
        }

        return self.fallbackCollection.first { $0.version == currentVersion }
    }

    // MARK: - GitHub API

    private static func fetchFromGitHub(
        for version: WhatsNew.Version,
        session: URLSession = .shared
    ) async -> WhatsNew? {
        for tag in self.releaseTags(for: version) {
            guard let whatsNew = await fetchRelease(tag: tag, session: session) else {
                continue
            }

            guard whatsNew.version == version else {
                DiagnosticsLogger.app.debug(
                    "Ignoring release notes for \(whatsNew.version.description); expected \(version.description)"
                )
                continue
            }

            return whatsNew
        }

        // KasetPlus releases are tagged `v{version}-kp.N` (e.g. v0.13.0-kp.21),
        // so the exact-tag lookup above never matches the bare app version
        // (0.13.0). Fall back to the latest release and accept it when its core
        // (major.minor.patch) matches — i.e. it's a `-kp` build of this version.
        if let latest = await fetchLatest(session: session),
           latest.version.hasSameCore(as: version)
        {
            return latest
        }

        return nil
    }

    /// Fetches the repo's latest published release.
    private static func fetchLatest(session: URLSession = .shared) async -> WhatsNew? {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.owner)/\(Self.repo)/releases/latest")
        else { return nil }
        return await Self.performRequest(url: url, session: session)
    }

    /// Returns semantically equivalent tag spellings without considering another app version.
    private static func releaseTags(for version: WhatsNew.Version) -> [String] {
        let canonicalCore = "\(version.major).\(version.minor).\(version.patch)"
        let suffix = version.description.dropFirst(canonicalCore.count)
        var tags = ["v\(version.description)"]

        guard version.patch == 0 else {
            return tags
        }

        tags.append("v\(version.major).\(version.minor)\(suffix)")
        if version.minor == 0 {
            tags.append("v\(version.major)\(suffix)")
        }

        return tags
    }

    /// Fetches a release by tag — useful for testing a specific version.
    static func fetchForTag(_ tag: String, session: URLSession = .shared) async -> WhatsNew? {
        let urlString = "https://api.github.com/repos/\(Self.owner)/\(Self.repo)/releases/tags/\(tag)"
        guard let url = URL(string: urlString) else { return nil }
        return await Self.performRequest(url: url, session: session)
    }

    private static func fetchRelease(tag: String, session: URLSession = .shared) async -> WhatsNew? {
        await self.fetchForTag(tag, session: session)
    }

    private static func performRequest(url: URL, session: URLSession = .shared) async -> WhatsNew? {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200
            else {
                return nil
            }
            return Self.parseRelease(data: data)
        } catch {
            DiagnosticsLogger.app.debug("Failed to fetch release notes: \(error.localizedDescription)")
            return nil
        }
    }

    private static func parseRelease(data: Data) -> WhatsNew? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String,
              let body = json["body"] as? String,
              let htmlURL = json["html_url"] as? String
        else {
            return nil
        }

        let versionString = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        let version = WhatsNew.Version(stringLiteral: versionString)
        let name = json["name"] as? String
        let title = name ?? "What's New in KasetPlus \(versionString)"

        return WhatsNew(
            version: version,
            title: title,
            releaseNotes: Self.cleanReleaseBody(body),
            learnMoreURL: URL(string: htmlURL)
        )
    }

    /// Cleans up GitHub release body by extracting the preferred changelog section
    /// when present, while stripping wrapper sections that the sheet UI doesn't need.
    private static func cleanReleaseBody(_ body: String) -> String {
        let hiddenHeadings: Set = [
            "whats new",
            "whats changed",
            "installation",
            "verification",
            "new contributors",
            "full changelog",
        ]
        let preferredHeadings: Set = [
            "whats new",
            "whats changed",
        ]

        let normalizedBody = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalizedBody.components(separatedBy: "\n")
        // Prefer the "What's New" section. Our release notes, though, keep the
        // changelog in sibling headings under a bare "### What's New" marker, so
        // that section extracts empty — fall back to the whole body (the
        // hidden-section pass below still drops the "What's New" wrapper).
        let extracted = Self.extractSection(from: lines, preferredHeadings: preferredHeadings)
        let relevantLines: [String] = if let extracted, !Self.collapsingBlankLines(in: extracted).isEmpty {
            extracted
        } else {
            lines
        }
        let result = Self.removingHiddenSections(from: relevantLines, hiddenHeadings: hiddenHeadings)
        let collapsedResult = Self.collapsingBlankLines(in: result)

        return collapsedResult.joined(separator: "\n")
    }

    private static func extractSection(from lines: [String], preferredHeadings: Set<String>) -> [String]? {
        guard let startIndex = lines.firstIndex(where: { line in
            guard let heading = Self.markdownHeading(in: line) else {
                return false
            }
            return preferredHeadings.contains(heading.text)
        }),
            let startHeading = markdownHeading(in: lines[startIndex])
        else {
            return nil
        }

        var result: [String] = []
        var index = startIndex + 1

        while index < lines.count {
            if let heading = Self.markdownHeading(in: lines[index]), heading.level <= startHeading.level {
                break
            }

            result.append(lines[index])
            index += 1
        }

        return result
    }

    private static func removingHiddenSections(from lines: [String], hiddenHeadings: Set<String>) -> [String] {
        var result: [String] = []
        var hiddenSectionLevel: Int?
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let heading = Self.markdownHeading(in: line)

            if let hiddenSectionLevel {
                if let heading, heading.level <= hiddenSectionLevel {
                    // Resume at the next sibling heading and evaluate it normally.
                } else {
                    index += 1
                    continue
                }
            }

            if let heading, hiddenHeadings.contains(heading.text) {
                hiddenSectionLevel = heading.level
                index += 1
                continue
            }

            hiddenSectionLevel = nil
            result.append(line)
            index += 1
        }

        return result
    }

    private static func collapsingBlankLines(in lines: [String]) -> [String] {
        var collapsedResult: [String] = []
        var previousWasBlank = false

        for line in lines {
            let isBlank = line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isBlank, previousWasBlank {
                continue
            }

            collapsedResult.append(line)
            previousWasBlank = isBlank
        }

        // Trim leading/trailing blank lines
        while collapsedResult.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            collapsedResult.removeFirst()
        }
        while collapsedResult.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            collapsedResult.removeLast()
        }

        return collapsedResult
    }

    private static func markdownHeading(in line: String) -> (level: Int, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "#" else {
            return nil
        }

        let level = trimmed.prefix(while: { $0 == "#" }).count
        guard (1 ... 6).contains(level) else {
            return nil
        }

        let remainder = String(trimmed.dropFirst(level))
        guard remainder.first == " " else {
            return nil
        }

        var text = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trailingHashes = text.range(of: #"\s+#+$"#, options: .regularExpression) {
            text.removeSubrange(trailingHashes)
        }

        return (level, Self.normalizedHeadingText(text))
    }

    private static func normalizedHeadingText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
