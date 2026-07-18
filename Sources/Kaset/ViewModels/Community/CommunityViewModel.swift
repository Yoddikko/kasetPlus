import Foundation
import Observation

/// Backs the in-app community screens (Report an issue + Discussions).
@MainActor
@Observable
final class CommunityViewModel {
    // Issues
    private(set) var issues: [GitHubIssue] = []
    private(set) var isLoadingIssues = false
    private(set) var templates: [GitHubIssueTemplate] = []

    // Discussions
    private(set) var discussions: [GitHubDiscussion] = []
    private(set) var categories: [GitHubDiscussionCategory] = []
    private(set) var isLoadingDiscussions = false

    private(set) var errorMessage: String?
    private(set) var isSubmitting = false

    private let client = GitHubClient.shared
    private let auth = GitHubAuthService.shared

    // MARK: - Issues

    func loadIssues() async {
        self.isLoadingIssues = true
        defer { self.isLoadingIssues = false }
        do {
            self.issues = try await self.client.listIssues()
        } catch {
            self.setError(error)
        }
    }

    func loadTemplates() async {
        guard self.templates.isEmpty else { return }
        self.templates = (try? await self.client.issueTemplates()) ?? [.blank]
    }

    /// Creates an issue, appending the auto-collected diagnostics block.
    func submitIssue(title: String, body: String, labels: [String], includeDiagnostics: Bool) async -> GitHubIssue? {
        guard !self.isSubmitting else { return nil }
        self.isSubmitting = true
        defer { self.isSubmitting = false }
        let fullBody = includeDiagnostics ? body + DiagnosticsReport.markdown(includingLogs: true) : body
        do {
            let issue = try await self.client.createIssue(title: title, body: fullBody, labels: labels)
            self.issues.insert(issue, at: 0)
            HapticService.success()
            return issue
        } catch {
            self.setError(error)
            HapticService.error()
            return nil
        }
    }

    // MARK: - Discussions

    func loadDiscussions() async {
        self.isLoadingDiscussions = true
        defer { self.isLoadingDiscussions = false }
        do {
            async let discussions = self.client.listDiscussions()
            async let categories = self.client.discussionCategories()
            self.discussions = try await discussions
            self.categories = (try? await categories) ?? []
        } catch {
            self.setError(error)
        }
    }

    func toggleUpvote(_ discussion: GitHubDiscussion) async {
        guard let index = self.discussions.firstIndex(where: { $0.id == discussion.id }) else { return }
        do {
            let result = try await self.client.toggleUpvote(
                discussionID: discussion.id,
                upvote: !discussion.viewerHasUpvoted
            )
            let updated = self.discussions[index]
            self.discussions[index] = GitHubDiscussion(
                id: updated.id, number: updated.number, title: updated.title, body: updated.body,
                author: updated.author, category: updated.category,
                upvoteCount: result.count, commentCount: updated.commentCount,
                viewerHasUpvoted: result.upvoted, createdAt: updated.createdAt, url: updated.url
            )
            HapticService.toggle()
        } catch {
            self.setError(error)
        }
    }

    func submitDiscussion(title: String, body: String, categoryID: String) async -> GitHubDiscussion? {
        guard !self.isSubmitting else { return nil }
        self.isSubmitting = true
        defer { self.isSubmitting = false }
        do {
            let discussion = try await self.client.createDiscussion(title: title, body: body, categoryID: categoryID)
            self.discussions.insert(discussion, at: 0)
            HapticService.success()
            return discussion
        } catch {
            self.setError(error)
            HapticService.error()
            return nil
        }
    }

    func clearError() { self.errorMessage = nil }

    private func setError(_ error: Error) {
        if case GitHubError.notAuthenticated = error {
            self.errorMessage = String(localized: "Sign in with GitHub to do that.")
        } else {
            self.errorMessage = error.localizedDescription
        }
    }
}
