// SidebarProfileView.swift
// Kaset
//
// Profile section displayed at the bottom of the sidebar for account management.

import AppKit
import SwiftUI

// MARK: - SidebarProfileView

/// A profile section displayed at the bottom of the sidebar.
///
/// Shows the current user's account info with an option to switch accounts
/// if brand accounts are available.
struct SidebarProfileView: View {
    @Environment(AccountService.self) private var accountService
    @Environment(AuthService.self) private var authService

    @State private var showingAccountSwitcher = false
    @State private var showsCommunity = false
    @State private var showsSupport = false
    @State private var support = SupportManager.shared

    /// Warm red used for the "Support the project" affordance (transparent when
    /// idle, filled/gradient once the user is a supporter).
    private static let supportColor = Color(red: 1.0, green: 0.30, blue: 0.45)

    var body: some View {
        VStack(spacing: 6) {
            self.supportButton

            self.communityButton

            Group {
                if self.authService.hasPersonalAccount {
                    self.loggedInContent
                } else if self.authService.state.isLoggedIn {
                    self.loggedInGuestContent
                } else {
                    self.loggedOutContent
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .sheet(isPresented: self.$showsCommunity) {
            CommunityView()
        }
        .sheet(isPresented: self.$showsSupport) {
            SupportView()
        }
    }

    /// "Support the project" — opens the Ko-fi support sheet. Turns into a filled
    /// "Supporter" pill once the user has an active supporter status.
    private var supportButton: some View {
        Button {
            self.showsSupport = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: self.support.isSupporter ? "heart.fill" : "heart")
                    .font(.system(size: 12))
                Text(self.support.isSupporter ? "Supporter" : "Support the project", comment: "Sidebar support entry point")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                if self.support.isSupporter {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 11))
                }
            }
            .foregroundStyle(self.support.isSupporter ? Color.white : Self.supportColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(self.supportButtonBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "Support KasetPlus on Ko-fi"))
    }

    @ViewBuilder
    private var supportButtonBackground: some View {
        if self.support.isSupporter {
            LinearGradient(colors: [Self.supportColor, .purple], startPoint: .leading, endPoint: .trailing)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Self.supportColor.opacity(0.14))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Self.supportColor.opacity(0.30), lineWidth: 1)
                }
        }
    }

    /// Opens the in-app community hub (report/browse issues + discussions).
    private var communityButton: some View {
        Button {
            self.showsCommunity = true
        } label: {
            HStack(spacing: 8) {
                GitHubMark(size: 13)
                Text("Report an issue or discuss", comment: "Sidebar community entry point")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "Report an issue or join the KasetPlus community"))
    }

    // MARK: - Logged In Content

    @ViewBuilder
    private var loggedInContent: some View {
        if let account = accountService.currentAccount {
            Button {
                self.showingAccountSwitcher = true
            } label: {
                HStack(spacing: 10) {
                    // Avatar
                    self.avatarView(for: account)

                    // Name and handle
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.name)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .foregroundStyle(.primary)

                        if let handle = account.handle {
                            Text(handle)
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    // Chevron indicator for account/guest switching.
                    if self.accountService.hasBrandAccounts || self.authService.state.isLoggedIn {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.SidebarProfile.profileButton)
            .accessibilityLabel(self.profileAccessibilityLabel(for: account))
            .accessibilityHint(String(localized: "Double-tap to switch accounts or guest mode"))
            .popover(isPresented: self.$showingAccountSwitcher, arrowEdge: .top) {
                AccountSwitcherPopover()
                    .environment(self.authService)
                    .environment(self.accountService)
            }
        } else if self.accountService.isLoading {
            // Loading state only while account data is actively being fetched.
            // If auth is stale but there is no current account, show the guest
            // sign-in affordance instead of a permanent skeleton.
            self.loadingStateView
        } else if self.accountService.lastError != nil {
            // Error state - show retry option
            self.errorStateView
        } else {
            self.missingAccountContent
        }
    }

    private var missingAccountContent: some View {
        Button {
            Task {
                await self.accountService.fetchAccounts()
            }
        } label: {
            self.guestModeLabel(subtitle: String(localized: "Loading account…"))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.SidebarProfile.loadingState)
        .accessibilityLabel(String(localized: "Loading account"))
        .accessibilityHint(String(localized: "Double-tap to retry loading accounts"))
    }

    // MARK: - Loading State

    private var loadingStateView: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.quaternary)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.quaternary)
                    .frame(width: 80, height: 12)

                RoundedRectangle(cornerRadius: 2)
                    .fill(.quaternary)
                    .frame(width: 60, height: 10)
            }

            Spacer()
        }
        .accessibilityIdentifier(AccessibilityID.SidebarProfile.loadingState)
    }

    // MARK: - Error State

    private var errorStateView: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Failed to load"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)

                Text(String(localized: "Tap to retry"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            Task {
                self.accountService.clearError()
                await self.accountService.fetchAccounts()
            }
        }
        .accessibilityIdentifier(AccessibilityID.SidebarProfile.errorState)
        .accessibilityLabel(String(localized: "Failed to load accounts"))
        .accessibilityHint(String(localized: "Double-tap to retry"))
    }

    private var loggedInGuestContent: some View {
        Button {
            self.showingAccountSwitcher = true
        } label: {
            self.guestModeLabel(subtitle: String(localized: "Switch back to your account"))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.SidebarProfile.profileButton)
        .accessibilityLabel(String(localized: "Guest mode. Switch back to your account."))
        .popover(isPresented: self.$showingAccountSwitcher, arrowEdge: .top) {
            AccountSwitcherPopover()
                .environment(self.authService)
                .environment(self.accountService)
        }
    }

    // MARK: - Logged Out Content

    private var loggedOutContent: some View {
        Button {
            self.authService.startLogin()
        } label: {
            self.guestModeLabel(subtitle: String(localized: "Sign in for your library"))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.SidebarProfile.loggedOutState)
        .accessibilityLabel(String(localized: "Guest mode. Sign in for your library."))
    }

    private func guestModeLabel(subtitle: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Guest Mode"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .contentShape(Rectangle())
    }

    // MARK: - Avatar View

    @ViewBuilder
    private func avatarView(for account: UserAccount) -> some View {
        if let thumbnailURL = account.thumbnailURL {
            CachedAsyncImage(url: thumbnailURL, targetSize: CGSize(width: 32, height: 32)) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                self.avatarPlaceholder
            }
            .frame(width: 32, height: 32)
            .clipShape(.circle)
        } else {
            self.avatarPlaceholder
        }
    }

    private var avatarPlaceholder: some View {
        Circle()
            .fill(.quaternary)
            .frame(width: 32, height: 32)
            .overlay {
                Image(systemName: "person.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            }
    }

    // MARK: - Accessibility

    private func profileAccessibilityLabel(for account: UserAccount) -> String {
        var label = "Profile: \(account.name)"
        if let handle = account.handle {
            label += ", \(handle)"
        }
        if self.accountService.hasBrandAccounts {
            label += ". Multiple accounts available."
        }
        return label
    }
}

// MARK: - AccessibilityID.SidebarProfile

extension AccessibilityID {
    enum SidebarProfile {
        static let container = "sidebarProfile"
        static let profileButton = "sidebarProfile.profileButton"
        static let loadingState = "sidebarProfile.loading"
        static let errorState = "sidebarProfile.error"
        static let loggedOutState = "sidebarProfile.loggedOut"
    }
}

// MARK: - Preview

#Preview("With Account") {
    let authService = AuthService()
    let ytMusicClient = YTMusicClient(authService: authService)
    let accountService = AccountService(ytMusicClient: ytMusicClient, authService: authService)

    SidebarProfileView()
        .environment(accountService)
        .environment(authService)
        .frame(width: 220)
        .padding()
}

#Preview("Logged Out") {
    let authService = AuthService()
    let ytMusicClient = YTMusicClient(authService: authService)
    let accountService = AccountService(ytMusicClient: ytMusicClient, authService: authService)

    SidebarProfileView()
        .environment(accountService)
        .environment(authService)
        .frame(width: 220)
        .padding()
}

// MARK: - GitHubMark

/// The GitHub mark, rendered from an embedded SVG so it needs no asset catalog
/// or bundle lookup. Drawn as a template image so it tints with `foregroundStyle`.
/// Falls back to an SF Symbol if SVG rasterization is unavailable.
struct GitHubMark: View {
    var size: CGFloat = 13

    private static let image: NSImage? = {
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0 0 16 8c0-4.42-3.58-8-8-8z"/></svg>"#
        guard let data = svg.data(using: .utf8), let image = NSImage(data: data) else { return nil }
        image.isTemplate = true
        return image
    }()

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: self.size, height: self.size)
        } else {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: self.size))
        }
    }
}
