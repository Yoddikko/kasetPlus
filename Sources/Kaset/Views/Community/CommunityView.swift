import SwiftUI

/// The in-app community hub: report/browse GitHub issues and browse/vote/create
/// GitHub Discussions for KasetPlus, all in native SwiftUI.
struct CommunityView: View {
    @State private var viewModel = CommunityViewModel()
    @State private var auth = GitHubAuthService.shared
    @State private var tab: Tab = .issues
    @State private var showsCompose = false
    @Environment(\.dismiss) private var dismiss

    enum Tab: Hashable {
        case issues
        case discussions
    }

    var body: some View {
        VStack(spacing: 0) {
            self.header
            Divider()
            self.content
        }
        .frame(minWidth: 620, minHeight: 560)
        .sheet(isPresented: self.$showsCompose) {
            switch self.tab {
            case .issues:
                IssueComposeView(viewModel: self.viewModel)
            case .discussions:
                DiscussionComposeView(viewModel: self.viewModel)
            }
        }
        .task {
            await self.viewModel.loadIssues()
            await self.viewModel.loadTemplates()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                Text("KasetPlus Community", comment: "Community window title")
                    .font(.title2.bold())
                Spacer()
                self.accountControl
            }

            Picker("", selection: self.$tab) {
                Label("Report an issue", systemImage: "ladybug").tag(Tab.issues)
                Label("Discussions", systemImage: "bubble.left.and.bubble.right").tag(Tab.discussions)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: self.tab) { _, newValue in
                if newValue == .discussions, self.viewModel.discussions.isEmpty {
                    Task { await self.viewModel.loadDiscussions() }
                }
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var accountControl: some View {
        switch self.auth.state {
        case let .signedIn(user):
            Menu {
                Button(String(localized: "Sign Out"), role: .destructive) {
                    self.auth.signOut()
                }
            } label: {
                HStack(spacing: 6) {
                    CachedAsyncImage(url: user.avatarURL, targetSize: CGSize(width: 22, height: 22)) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Circle().fill(.quaternary)
                    }
                    .frame(width: 22, height: 22)
                    .clipShape(.circle)
                    Text(user.login)
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        default:
            EmptyView()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        ZStack(alignment: .bottom) {
            switch self.tab {
            case .issues:
                IssuesTabView(viewModel: self.viewModel, onCompose: { self.startCompose() })
            case .discussions:
                DiscussionsTabView(
                    viewModel: self.viewModel,
                    requiresSignIn: !self.auth.isSignedIn,
                    onCompose: { self.startCompose() }
                )
            }

            if let error = self.viewModel.errorMessage {
                self.errorBanner(error)
            }
        }
    }

    private func startCompose() {
        if self.auth.isSignedIn {
            self.showsCompose = true
        } else {
            // Composing needs auth; the sign-in sheet handles the rest.
            self.showsCompose = false
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message).font(.system(size: 12))
            Spacer()
            Button {
                self.viewModel.clearError()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(10)
        .background(.red.opacity(0.9), in: RoundedRectangle(cornerRadius: 10))
        .padding(12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - Sign-in gate

/// A compact sign-in call-to-action used when an action needs GitHub auth.
struct GitHubSignInGate: View {
    @State private var auth = GitHubAuthService.shared

    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(self.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            switch self.auth.state {
            case .connecting:
                ProgressView()
            case let .awaitingAuthorization(userCode, verificationURL):
                VStack(spacing: 8) {
                    Text("Enter this code at github.com/login/device:", comment: "Device-flow instructions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(userCode)
                        .font(.system(.title2, design: .monospaced).bold())
                        .textSelection(.enabled)
                    Link(destination: verificationURL) {
                        Label("Open GitHub", systemImage: "arrow.up.forward.app")
                    }
                }
            default:
                if GitHubConfig.isLoginConfigured {
                    Button {
                        Task { await self.auth.startLogin() }
                    } label: {
                        Label("Sign in with GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Text("GitHub sign-in isn't configured in this build.", comment: "OAuth client id missing")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
