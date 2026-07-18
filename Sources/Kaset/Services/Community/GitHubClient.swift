import Foundation

/// Talks to GitHub's REST (issues, templates) and GraphQL (discussions) APIs for
/// the in-app community. Reads the bearer token from ``GitHubAuthService`` when
/// signed in; public reads (open issues) work unauthenticated too.
@MainActor
final class GitHubClient {
    static let shared = GitHubClient()

    private let restBase = "https://api.github.com"
    private let graphQLURL = URL(string: "https://api.github.com/graphql")!
    private let owner = GitHubConfig.owner
    private let repo = GitHubConfig.repo

    private var token: String? { GitHubAuthService.shared.token }

    private init() {}

    // MARK: - Issues (REST)

    func listIssues(state: String = "open") async throws -> [GitHubIssue] {
        // `issues` also returns PRs; filter them out below.
        let path = "/repos/\(self.owner)/\(self.repo)/issues?state=\(state)&per_page=40&sort=created&direction=desc"
        let data = try await self.rest(path)
        let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        return items.compactMap(Self.issue(from:)).filter { _ in true }
    }

    func createIssue(title: String, body: String, labels: [String]) async throws -> GitHubIssue {
        guard self.token != nil else { throw GitHubError.notAuthenticated }
        var payload: [String: Any] = ["title": title, "body": body]
        if !labels.isEmpty { payload["labels"] = labels }
        let data = try await self.rest(
            "/repos/\(self.owner)/\(self.repo)/issues",
            method: "POST",
            body: JSONSerialization.data(withJSONObject: payload)
        )
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let issue = Self.issue(from: dict)
        else {
            throw GitHubError.decodingFailed
        }
        return issue
    }

    /// Fetches the repo's issue templates from `.github/ISSUE_TEMPLATE`.
    func issueTemplates() async throws -> [GitHubIssueTemplate] {
        let path = "/repos/\(self.owner)/\(self.repo)/contents/.github/ISSUE_TEMPLATE"
        let data: Data
        do {
            data = try await self.rest(path)
        } catch {
            return [.blank]
        }
        let files = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        var templates: [GitHubIssueTemplate] = []
        for file in files {
            guard let name = file["name"] as? String,
                  // config.yml is the template chooser config, not a template.
                  name != "config.yml", name != "config.yaml",
                  let downloadURL = (file["download_url"] as? String).flatMap(URL.init(string:))
            else { continue }
            guard let (_, raw) = try? await self.download(downloadURL),
                  let text = String(data: raw, encoding: .utf8)
            else { continue }

            if name.hasSuffix(".md") {
                templates.append(Self.parseTemplate(filename: name, markdown: text))
            } else if name.hasSuffix(".yml") || name.hasSuffix(".yaml") {
                templates.append(Self.parseFormTemplate(filename: name, yaml: text))
            }
        }
        templates.append(.blank)
        return templates
    }

    // MARK: - Discussions (GraphQL)

    func listDiscussions() async throws -> [GitHubDiscussion] {
        let query = """
        query($owner:String!, $repo:String!) {
          repository(owner:$owner, name:$repo) {
            discussions(first: 30, orderBy: {field: UPDATED_AT, direction: DESC}) {
              nodes {
                id number title bodyText url createdAt upvoteCount viewerHasUpvoted
                author { login avatarUrl }
                category { id name emoji emojiHTML description isAnswerable }
                comments { totalCount }
              }
            }
          }
        }
        """
        let json = try await self.graphQL(query, variables: ["owner": self.owner, "repo": self.repo])
        let nodes = self.dig(json, "data", "repository", "discussions", "nodes") as? [[String: Any]] ?? []
        return nodes.compactMap(Self.discussion(from:))
    }

    func discussionCategories() async throws -> [GitHubDiscussionCategory] {
        let query = """
        query($owner:String!, $repo:String!) {
          repository(owner:$owner, name:$repo) {
            discussionCategories(first: 25) {
              nodes { id name emoji emojiHTML description isAnswerable }
            }
          }
        }
        """
        let json = try await self.graphQL(query, variables: ["owner": self.owner, "repo": self.repo])
        let nodes = self.dig(json, "data", "repository", "discussionCategories", "nodes") as? [[String: Any]] ?? []
        return nodes.compactMap(Self.category(from:))
    }

    func toggleUpvote(discussionID: String, upvote: Bool) async throws -> (count: Int, upvoted: Bool) {
        guard self.token != nil else { throw GitHubError.notAuthenticated }
        let mutation = upvote ? "addUpvote" : "removeUpvote"
        let query = """
        mutation($id:ID!) {
          \(mutation)(input:{subjectId:$id}) {
            subject { ... on Discussion { upvoteCount viewerHasUpvoted } }
          }
        }
        """
        let json = try await self.graphQL(query, variables: ["id": discussionID])
        let subject = self.dig(json, "data", mutation, "subject") as? [String: Any]
        return (subject?["upvoteCount"] as? Int ?? 0, subject?["viewerHasUpvoted"] as? Bool ?? upvote)
    }

    func createDiscussion(title: String, body: String, categoryID: String) async throws -> GitHubDiscussion {
        guard self.token != nil else { throw GitHubError.notAuthenticated }
        let repoID = try await self.repositoryID()
        let query = """
        mutation($repo:ID!, $cat:ID!, $title:String!, $body:String!) {
          createDiscussion(input:{repositoryId:$repo, categoryId:$cat, title:$title, body:$body}) {
            discussion {
              id number title bodyText url createdAt upvoteCount viewerHasUpvoted
              author { login avatarUrl }
              category { id name emoji emojiHTML description isAnswerable }
              comments { totalCount }
            }
          }
        }
        """
        let json = try await self.graphQL(query, variables: [
            "repo": repoID, "cat": categoryID, "title": title, "body": body,
        ])
        guard let node = self.dig(json, "data", "createDiscussion", "discussion") as? [String: Any],
              let discussion = Self.discussion(from: node)
        else {
            throw GitHubError.decodingFailed
        }
        return discussion
    }

    private func repositoryID() async throws -> String {
        let query = "query($owner:String!,$repo:String!){ repository(owner:$owner,name:$repo){ id } }"
        let json = try await self.graphQL(query, variables: ["owner": self.owner, "repo": self.repo])
        guard let id = self.dig(json, "data", "repository", "id") as? String else {
            throw GitHubError.decodingFailed
        }
        return id
    }

    // MARK: - Transport

    private func rest(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: URL(string: self.restBase + path)!)
        request.httpMethod = method
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else { throw GitHubError.requestFailed(status) }
        return data
    }

    private func download(_ url: URL) async throws -> (URLResponse, Data) {
        let (data, response) = try await URLSession.shared.data(from: url)
        return (response, data)
    }

    private func graphQL(_ query: String, variables: [String: Any]) async throws -> [String: Any] {
        guard let token else { throw GitHubError.notAuthenticated }
        var request = URLRequest(url: self.graphQLURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw GitHubError.requestFailed(status) }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func dig(_ root: Any?, _ keys: String...) -> Any? {
        var current = root
        for key in keys {
            current = (current as? [String: Any])?[key]
        }
        return current
    }

    // MARK: - Parsing

    private static let isoFormatter = ISO8601DateFormatter()

    private static func issue(from dict: [String: Any]) -> GitHubIssue? {
        // Pull requests come through the issues endpoint too; skip them.
        if dict["pull_request"] != nil { return nil }
        guard let id = dict["id"] as? Int,
              let number = dict["number"] as? Int,
              let title = dict["title"] as? String
        else { return nil }
        let labels = (dict["labels"] as? [[String: Any]] ?? []).compactMap { label -> GitHubLabel? in
            guard let name = label["name"] as? String else { return nil }
            return GitHubLabel(id: label["id"] as? Int ?? 0, name: name, color: label["color"] as? String ?? "888888")
        }
        return GitHubIssue(
            id: id,
            number: number,
            title: title,
            body: dict["body"] as? String ?? "",
            state: dict["state"] as? String ?? "open",
            author: Self.user(from: dict["user"]),
            labels: labels,
            commentCount: dict["comments"] as? Int ?? 0,
            createdAt: Self.date(dict["created_at"]),
            url: (dict["html_url"] as? String).flatMap(URL.init(string:))
        )
    }

    private static func discussion(from dict: [String: Any]) -> GitHubDiscussion? {
        guard let id = dict["id"] as? String,
              let number = dict["number"] as? Int,
              let title = dict["title"] as? String
        else { return nil }
        return GitHubDiscussion(
            id: id,
            number: number,
            title: title,
            body: dict["bodyText"] as? String ?? "",
            author: Self.user(from: dict["author"]),
            category: Self.category(from: dict["category"] as? [String: Any] ?? [:]),
            upvoteCount: dict["upvoteCount"] as? Int ?? 0,
            commentCount: (dict["comments"] as? [String: Any])?["totalCount"] as? Int ?? 0,
            viewerHasUpvoted: dict["viewerHasUpvoted"] as? Bool ?? false,
            createdAt: Self.date(dict["createdAt"]),
            url: (dict["url"] as? String).flatMap(URL.init(string:))
        )
    }

    private static func category(from dict: [String: Any]) -> GitHubDiscussionCategory? {
        guard let id = dict["id"] as? String, let name = dict["name"] as? String else { return nil }
        return GitHubDiscussionCategory(
            id: id,
            name: name,
            emoji: Self.emoji(from: dict),
            description: dict["description"] as? String ?? "",
            isAnswerable: dict["isAnswerable"] as? Bool ?? false
        )
    }

    /// The category's emoji as an actual character. GraphQL's `emoji` is a
    /// shortcode (`:mega:`); `emojiHTML` wraps the real glyph in tags, so strip
    /// the tags to recover it.
    private static func emoji(from dict: [String: Any]) -> String {
        if let html = dict["emojiHTML"] as? String {
            let stripped = html
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !stripped.isEmpty { return stripped }
        }
        return dict["emoji"] as? String ?? "💬"
    }

    private static func user(from value: Any?) -> GitHubUser? {
        guard let dict = value as? [String: Any], let login = dict["login"] as? String else { return nil }
        let avatar = (dict["avatarUrl"] as? String ?? dict["avatar_url"] as? String).flatMap(URL.init(string:))
        return GitHubUser(id: dict["id"] as? Int ?? 0, login: login, avatarURL: avatar)
    }

    private static func date(_ value: Any?) -> Date {
        (value as? String).flatMap(Self.isoFormatter.date(from:)) ?? Date()
    }

    /// Parses a YAML front-matter issue template (`--- … ---` header + Markdown body).
    private static func parseTemplate(filename: String, markdown: String) -> GitHubIssueTemplate {
        var name = filename
        var about = ""
        var title = ""
        var labels: [String] = []
        var body = markdown

        if markdown.hasPrefix("---") {
            let parts = markdown.components(separatedBy: "---")
            if parts.count >= 3 {
                let frontMatter = parts[1]
                body = parts.dropFirst(2).joined(separator: "---").trimmingCharacters(in: .whitespacesAndNewlines)
                for line in frontMatter.split(separator: "\n") {
                    let pair = line.split(separator: ":", maxSplits: 1).map {
                        $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                    }
                    guard pair.count == 2 else { continue }
                    switch pair[0] {
                    case "name": name = pair[1]
                    case "about": about = pair[1]
                    case "title": title = pair[1]
                    case "labels": labels = pair[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    default: break
                    }
                }
            }
        }
        return GitHubIssueTemplate(
            filename: filename,
            name: name,
            about: about,
            titlePrefix: title,
            labels: labels,
            body: body
        )
    }

    /// Parses a GitHub **issue form** (`.yml`). We can't render the form natively,
    /// so pull the metadata (name/description/title/labels) and build a fillable
    /// Markdown body from each field's `label:` as a heading.
    private static func parseFormTemplate(filename: String, yaml: String) -> GitHubIssueTemplate {
        var name = filename
        var about = ""
        var title = ""
        var labels: [String] = []
        var sections: [String] = []

        func scalar(_ line: String) -> String {
            guard let colon = line.firstIndex(of: ":") else { return "" }
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'"))
            {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }

        let lines = yaml.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let isTopLevel = !line.hasPrefix(" ") && !line.hasPrefix("\t")
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if isTopLevel {
                if line.hasPrefix("name:") { name = scalar(line) }
                else if line.hasPrefix("description:") { about = scalar(line) }
                else if line.hasPrefix("title:") { title = scalar(line) }
                else if line.hasPrefix("labels:") {
                    let inline = scalar(line)
                    if inline.hasPrefix("[") {
                        labels = inline.dropFirst().dropLast()
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
                            .filter { !$0.isEmpty }
                    } else {
                        var next = index + 1
                        while next < lines.count {
                            let item = lines[next].trimmingCharacters(in: .whitespaces)
                            guard item.hasPrefix("-") else { break }
                            let label = String(item.dropFirst())
                                .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                            if !label.isEmpty { labels.append(label) }
                            next += 1
                        }
                    }
                }
            }

            if trimmed.hasPrefix("label:") {
                let label = scalar(trimmed)
                if !label.isEmpty { sections.append("### \(label)\n") }
            }
        }

        return GitHubIssueTemplate(
            filename: filename,
            name: name,
            about: about,
            titlePrefix: title,
            labels: labels,
            body: sections.joined(separator: "\n")
        )
    }
}
