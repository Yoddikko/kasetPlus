import Foundation

// MARK: - GitHub configuration

/// Static configuration for the in-app community (Issues + Discussions).
///
/// `clientID` must be the client ID of a GitHub **OAuth App** (registered at
/// https://github.com/settings/developers) with the *Device Flow* enabled. It
/// is not a secret — OAuth Device Flow needs no client secret — so it can ship
/// in the app. Until a real ID is set, sign-in is disabled and only public,
/// read-only data (issues) is available.
enum GitHubConfig {
    /// The repository the community features target.
    static let owner = "Yoddikko"
    static let repo = "kasetPlus"

    /// OAuth App client ID (Device Flow enabled). This is **not** a secret —
    /// Device Flow uses no client secret and the ID ships inside the binary
    /// anyway — so it's safe to commit in this open-source app.
    static let clientID = "Ov23liqdaRDcP5EDvKRs"

    /// Scopes requested during the device-flow login. `public_repo` covers
    /// creating issues, commenting, and creating/upvoting Discussions on a public
    /// repo. (`read:/write:discussion` are for org *team* discussions, not repo
    /// Discussions, so they aren't needed here.)
    static let scopes = "public_repo"

    static var isLoginConfigured: Bool { !Self.clientID.isEmpty }

    static var repoSlug: String { "\(Self.owner)/\(Self.repo)" }
}

// MARK: - GitHubUser

struct GitHubUser: Identifiable, Hashable, Codable {
    let id: Int
    let login: String
    let avatarURL: URL?

    enum CodingKeys: String, CodingKey {
        case id, login
        case avatarURL = "avatar_url"
    }
}

// MARK: - GitHubLabel

struct GitHubLabel: Identifiable, Hashable, Codable {
    var id: Int
    let name: String
    /// Hex color without the leading `#`.
    let color: String
}

// MARK: - GitHubIssue

struct GitHubIssue: Identifiable, Hashable {
    let id: Int
    let number: Int
    let title: String
    let body: String
    let state: String
    let author: GitHubUser?
    let labels: [GitHubLabel]
    let commentCount: Int
    let createdAt: Date
    let url: URL?

    var isOpen: Bool { self.state == "open" }
}

// MARK: - GitHubIssueTemplate

/// An issue template from the repo's `.github/ISSUE_TEMPLATE`, used to prefill
/// the compose form the way GitHub's "New issue" chooser does.
struct GitHubIssueTemplate: Identifiable, Hashable {
    var id: String { self.filename }
    let filename: String
    /// Display name (`name:` in YAML front-matter, else the filename).
    let name: String
    /// Short description (`about:`).
    let about: String
    /// Prefilled title (`title:`), if any.
    let titlePrefix: String
    /// Labels the template applies (`labels:`).
    let labels: [String]
    /// The Markdown body the template starts the issue with.
    let body: String

    /// A blank template for a free-form report.
    static let blank = GitHubIssueTemplate(
        filename: "blank",
        name: "Blank issue",
        about: "Open a blank issue",
        titlePrefix: "",
        labels: [],
        body: ""
    )
}

// MARK: - GitHubDiscussionCategory

struct GitHubDiscussionCategory: Identifiable, Hashable {
    let id: String
    let name: String
    let emoji: String
    let description: String
    let isAnswerable: Bool
}

// MARK: - GitHubDiscussion

struct GitHubDiscussion: Identifiable, Hashable {
    /// GraphQL node id (used for mutations like upvote).
    let id: String
    let number: Int
    let title: String
    let body: String
    let author: GitHubUser?
    let category: GitHubDiscussionCategory?
    let upvoteCount: Int
    let commentCount: Int
    let viewerHasUpvoted: Bool
    let createdAt: Date
    let url: URL?
}

// MARK: - GitHubComment

struct GitHubComment: Identifiable, Hashable {
    let id: String
    let author: GitHubUser?
    let body: String
    let createdAt: Date
    let upvoteCount: Int?
}
