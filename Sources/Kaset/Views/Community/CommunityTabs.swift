import SwiftUI

// MARK: - Issues tab

struct IssuesTabView: View {
    @Bindable var viewModel: CommunityViewModel
    let onCompose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            self.toolbar
            Divider()
            if self.viewModel.isLoadingIssues, self.viewModel.issues.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if self.viewModel.issues.isEmpty {
                CommunityEmptyState(
                    icon: "ladybug.fill",
                    title: String(localized: "No open issues"),
                    subtitle: String(localized: "Found a bug or have an idea? Report it — logs and specs are attached for you."),
                    ctaTitle: String(localized: "Report an issue"),
                    onCTA: self.onCompose
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(self.viewModel.issues) { issue in
                            IssueRow(issue: issue)
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var toolbar: some View {
        HStack {
            Text("\(self.viewModel.issues.count) open", comment: "Open issue count")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: self.onCompose) {
                Label("New issue", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

private struct IssueRow: View {
    let issue: GitHubIssue

    var body: some View {
        Link(destination: self.issue.url ?? URL(string: "https://github.com")!) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: self.issue.isOpen ? "smallcircle.filled.circle" : "checkmark.circle.fill")
                    .foregroundStyle(self.issue.isOpen ? .green : .purple)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text(self.issue.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 8) {
                        Text("#\(self.issue.number)")
                        if let author = self.issue.author { Text("by \(author.login)") }
                        Label("\(self.issue.commentCount)", systemImage: "text.bubble")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)

                    if !self.issue.labels.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(self.issue.labels.prefix(4)) { label in
                                Text(label.name)
                                    .font(.system(size: 10, weight: .medium))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background((Color(hex: label.color) ?? .secondary).opacity(0.25), in: Capsule())
                                    .foregroundStyle(Color(hex: label.color) ?? .secondary)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Discussions tab

struct DiscussionsTabView: View {
    @Bindable var viewModel: CommunityViewModel
    let onCompose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(self.viewModel.discussions.count) discussions", comment: "Discussion count")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: self.onCompose) {
                    Label("New discussion", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()

            if self.viewModel.isLoadingDiscussions, self.viewModel.discussions.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if self.viewModel.discussions.isEmpty {
                CommunityEmptyState(
                    icon: "bubble.left.and.bubble.right.fill",
                    title: String(localized: "No discussions yet"),
                    subtitle: String(localized: "Ask a question, share an idea, or just say hi to the community."),
                    ctaTitle: String(localized: "Start a discussion"),
                    onCTA: self.onCompose
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(self.viewModel.discussions) { discussion in
                            DiscussionRow(discussion: discussion) {
                                Task { await self.viewModel.toggleUpvote(discussion) }
                            }
                            Divider()
                        }
                    }
                }
            }
        }
        .task {
            if self.viewModel.discussions.isEmpty {
                await self.viewModel.loadDiscussions()
            }
        }
    }
}

private struct DiscussionRow: View {
    let discussion: GitHubDiscussion
    let onUpvote: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: self.onUpvote) {
                VStack(spacing: 2) {
                    Image(systemName: self.discussion.viewerHasUpvoted ? "arrowtriangle.up.fill" : "arrowtriangle.up")
                    Text("\(self.discussion.upvoteCount)")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(self.discussion.viewerHasUpvoted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .frame(width: 34)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            Link(destination: self.discussion.url ?? URL(string: "https://github.com")!) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if let category = self.discussion.category {
                            Text("\(category.emoji) \(category.name)")
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(self.discussion.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 8) {
                        if let author = self.discussion.author { Text("by \(author.login)") }
                        Label("\(self.discussion.commentCount)", systemImage: "text.bubble")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Empty state

/// A friendly empty state with a brand-tinted icon and a call to action.
struct CommunityEmptyState: View {
    let icon: String
    let title: String
    let subtitle: String
    let ctaTitle: String
    let onCTA: () -> Void

    private static let accent = PackageResourceLookup.brandAccent

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Self.accent.opacity(0.12))
                    .frame(width: 76, height: 76)
                Image(systemName: self.icon)
                    .font(.system(size: 30))
                    .foregroundStyle(Self.accent)
            }
            Text(self.title)
                .font(.title3.bold())
            Text(self.subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button(action: self.onCTA) {
                Label(self.ctaTitle, systemImage: "plus")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.borderedProminent)
            .tint(Self.accent)
            .controlSize(.large)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}
