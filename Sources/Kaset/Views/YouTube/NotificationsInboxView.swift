import SwiftUI

// MARK: - NotificationsBellButton

/// Toolbar bell that shows the unseen count as a red badge and toggles the
/// notification inbox panel. The panel itself is presented by `MainWindow` as a
/// top-trailing dropdown (no popover arrow) for consistent placement.
struct NotificationsBellButton: View {
    @Bindable var viewModel: YouTubeNotificationsViewModel
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            self.isPresented.toggle()
        } label: {
            Image(systemName: self.viewModel.unseenCount > 0 ? "bell.badge" : "bell")
                .font(.system(size: 14))
                .foregroundStyle(.primary)
                .overlay(alignment: .topTrailing) {
                    if self.viewModel.unseenCount > 0 {
                        NotificationCountBadge(count: self.viewModel.unseenCount)
                            .offset(x: 7, y: -7)
                    }
                }
        }
        .help(String(localized: "Notifications"))
        .accessibilityLabel(self.accessibilityLabel)
    }

    private var accessibilityLabel: String {
        self.viewModel.unseenCount > 0
            ? String(localized: "Notifications, \(self.viewModel.unseenCount) unread")
            : String(localized: "Notifications")
    }
}

// MARK: - NotificationCountBadge

private struct NotificationCountBadge: View {
    let count: Int

    var body: some View {
        Text(self.count > 9 ? "9+" : "\(self.count)")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .frame(minWidth: 15, minHeight: 15)
            .background(Color.red, in: Capsule())
    }
}

// MARK: - NotificationsInboxPanel

/// The dropdown inbox itself: a plain rounded material panel (no arrow).
struct NotificationsInboxPanel: View {
    @Bindable var viewModel: YouTubeNotificationsViewModel
    let onOpen: (YouTubeNotification) -> Void

    var body: some View {
        VStack(spacing: 0) {
            self.header

            Divider()

            self.content
        }
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.08))
        }
        .shadow(color: .black.opacity(0.28), radius: 16, x: 0, y: 8)
    }

    private var header: some View {
        HStack {
            Text(String(localized: "Notifications"))
                .font(.headline)
                .foregroundStyle(.primary)

            Spacer()

            if self.viewModel.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if self.viewModel.notifications.isEmpty {
            self.emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(self.viewModel.notifications) { notification in
                        NotificationRow(
                            notification: notification,
                            isNew: self.viewModel.isNew(notification)
                        ) {
                            self.onOpen(notification)
                        }

                        if notification.id != self.viewModel.notifications.last?.id {
                            Divider()
                                .padding(.leading, 64)
                                .opacity(0.25)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 360)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: self.viewModel.hasError ? "exclamationmark.triangle" : "bell.slash")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)

            Text(self.viewModel.hasError
                ? String(localized: "Couldn't load notifications")
                : String(localized: "You're all caught up"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }
}

// MARK: - NotificationRow

private struct NotificationRow: View {
    let notification: YouTubeNotification
    let isNew: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: self.onTap) {
            HStack(spacing: 12) {
                Circle()
                    .fill(self.isNew ? Color.blue : Color.clear)
                    .frame(width: 7, height: 7)

                CachedAsyncImage(
                    url: self.notification.thumbnailURL,
                    targetSize: CGSize(width: 96, height: 96)
                ) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary)
                }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 3) {
                    Text(self.notification.message)
                        .font(.system(size: 12))
                        .fontWeight(self.isNew ? .semibold : .regular)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)

                    if let time = self.notification.sentTimeText {
                        Text(time)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
