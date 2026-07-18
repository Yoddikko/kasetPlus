import SwiftUI

/// The in-app community hub: report/browse GitHub issues and browse/vote/create
/// GitHub Discussions for KasetPlus, all in native SwiftUI. Signed-out users see
/// a sign-in screen first.
struct CommunityView: View {
    @State private var viewModel = CommunityViewModel()
    @State private var auth = GitHubAuthService.shared
    @State private var tab: Tab = .issues
    @State private var showsCompose = false
    @Environment(\.dismiss) private var dismiss

    private static let accent = PackageResourceLookup.brandAccent

    enum Tab: Hashable {
        case issues
        case discussions
    }

    var body: some View {
        ZStack {
            if self.auth.isSignedIn {
                self.hub
            } else {
                CommunityLoginView()
            }
        }
        .frame(width: 680, height: 620)
        .background(.ultraThickMaterial)
        .overlay(alignment: .topTrailing) { self.closeButton }
        .sheet(isPresented: self.$showsCompose) {
            switch self.tab {
            case .issues: IssueComposeView(viewModel: self.viewModel)
            case .discussions: DiscussionComposeView(viewModel: self.viewModel)
            }
        }
    }

    private var closeButton: some View {
        Button { self.dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(.thinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .padding(14)
    }

    // MARK: - Hub (signed in)

    private var hub: some View {
        VStack(spacing: 0) {
            self.header
            Divider()
            ZStack(alignment: .bottom) {
                Group {
                    switch self.tab {
                    case .issues:
                        IssuesTabView(viewModel: self.viewModel, onCompose: { self.showsCompose = true })
                    case .discussions:
                        DiscussionsTabView(viewModel: self.viewModel, onCompose: { self.showsCompose = true })
                    }
                }
                if let error = self.viewModel.errorMessage {
                    self.errorToast(error)
                }
            }
        }
        .task {
            await self.viewModel.loadIssues()
            await self.viewModel.loadTemplates()
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Self.accent)
                Text("KasetPlus Community", comment: "Community window title")
                    .font(.title2.bold())
                Spacer()
                self.accountMenu
            }
            // Keep the account control clear of the close button in the corner.
            .padding(.trailing, 34)

            Picker("", selection: self.$tab) {
                Text("Report an issue").tag(Tab.issues)
                Text("Discussions").tag(Tab.discussions)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: self.tab) { _, newValue in
                if newValue == .discussions, self.viewModel.discussions.isEmpty {
                    Task { await self.viewModel.loadDiscussions() }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var accountMenu: some View {
        if case let .signedIn(user) = self.auth.state {
            Menu {
                Button(String(localized: "Sign Out"), role: .destructive) { self.auth.signOut() }
            } label: {
                HStack(spacing: 6) {
                    CachedAsyncImage(url: user.avatarURL, targetSize: CGSize(width: 22, height: 22)) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Circle().fill(.quaternary)
                    }
                    .frame(width: 22, height: 22)
                    .clipShape(.circle)
                    Text(user.login).font(.system(size: 12, weight: .medium))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func errorToast(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
            Text(message).font(.system(size: 12, weight: .medium)).lineLimit(2)
            Spacer(minLength: 4)
            Button { self.viewModel.clearError() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.red.opacity(0.5), lineWidth: 1))
        .padding(14)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - Login gate

/// The sign-in screen shown before anything else when signed out: a short pitch
/// plus the GitHub device-flow login.
struct CommunityLoginView: View {
    @State private var auth = GitHubAuthService.shared
    private static let accent = PackageResourceLookup.brandAccent

    var body: some View {
        VStack(spacing: 22) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Self.accent.gradient)
                    .frame(width: 84, height: 84)
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: Self.accent.opacity(0.4), radius: 16, y: 6)

            VStack(spacing: 6) {
                Text("KasetPlus Community", comment: "Login title")
                    .font(.title.bold())
                Text("Report issues and join the conversation — right inside the app.", comment: "Login subtitle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            VStack(alignment: .leading, spacing: 12) {
                self.feature("ladybug.fill", String(localized: "Report bugs with logs and specs attached automatically"))
                self.feature("bubble.left.and.bubble.right.fill", String(localized: "Browse and join community discussions"))
                self.feature("arrow.up.circle.fill", String(localized: "Upvote the ideas that matter to you"))
            }
            .padding(18)
            .frame(maxWidth: 380)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))

            self.signInSection

            Spacer()
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func feature(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Self.accent)
                .frame(width: 22)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var signInSection: some View {
        switch self.auth.state {
        case .connecting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Connecting to GitHub…", comment: "Device flow connecting")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

        case let .awaitingAuthorization(userCode, verificationURL):
            VStack(spacing: 12) {
                Text("Enter this code at github.com/login/device", comment: "Device-flow instructions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(userCode)
                    .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                    .tracking(4)
                    .textSelection(.enabled)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                Link(destination: verificationURL) {
                    Label("Open GitHub", systemImage: "arrow.up.forward.app.fill")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Self.accent)
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for authorization…", comment: "Device flow waiting")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Button(String(localized: "Cancel")) { self.auth.cancelLogin() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        default:
            VStack(spacing: 10) {
                Button {
                    Task { await self.auth.startLogin() }
                } label: {
                    Label("Sign in with GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(Self.accent)
                .controlSize(.large)
                .disabled(!GitHubConfig.isLoginConfigured)

                if !GitHubConfig.isLoginConfigured {
                    Text("GitHub sign-in isn't configured in this build yet.", comment: "OAuth client id missing")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
