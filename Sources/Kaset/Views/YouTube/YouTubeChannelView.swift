import SwiftUI

/// A YouTube channel page: header plus the landing-tab video grid.
struct YouTubeChannelView: View {
    @State private var viewModel: YouTubeChannelViewModel

    private static let columns = [
        GridItem(.adaptive(minimum: 210, maximum: 320), spacing: 16),
    ]

    init(channelId: String, client: any YouTubeClientProtocol) {
        self._viewModel = State(
            initialValue: YouTubeChannelViewModel(channelId: channelId, client: client)
        )
    }

    var body: some View {
        Group {
            switch self.viewModel.loadingState {
            case .idle, .loading:
                LoadingView()
            case let .error(error):
                ErrorView(
                    title: error.title,
                    message: error.message,
                    isRetryable: error.isRetryable
                ) {
                    Task {
                        await self.viewModel.load()
                    }
                }
            case .loaded, .loadingMore:
                if let detail = self.viewModel.detail {
                    self.content(for: detail)
                }
            }
        }
        .navigationTitle(Text(self.viewModel.detail?.channel.name ?? ""))
        .task {
            await self.viewModel.load()
        }
    }

    private func content(for detail: YouTubeChannelDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                self.header(for: detail.channel)
                self.tabBar
                self.tabContent(for: detail)
            }
            .padding(.vertical, 20)
        }
        // Edge-to-edge with a resting inset so content extends under the
        // floating glass sidebar.
        .contentMargins(.horizontal, DetailContentLayout.horizontalInset, for: .scrollContent)
    }

    // MARK: - Tabs

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 22) {
                ForEach(YouTubeChannelTab.allCases) { tab in
                    let selected = self.viewModel.selectedTab == tab
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            self.viewModel.selectTab(tab)
                        }
                    } label: {
                        VStack(spacing: 5) {
                            Text(tab.title)
                                .font(.system(size: 15, weight: selected ? .semibold : .regular))
                                .foregroundStyle(selected ? Color.primary : Color.secondary)
                            Capsule()
                                .fill(selected ? Color.primary : Color.clear)
                                .frame(height: 2)
                        }
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 1)
        }
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private func tabContent(for detail: YouTubeChannelDetail) -> some View {
        let tab = self.viewModel.selectedTab
        if self.viewModel.loadingTabs.contains(tab) {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
        } else if self.viewModel.failedTabs.contains(tab) {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title)
                    .foregroundStyle(.secondary)
                Text("Couldn't load this tab", comment: "Channel tab load error")
                    .foregroundStyle(.secondary)
                Button(String(localized: "Retry")) {
                    Task { await self.viewModel.loadTab(tab) }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else if tab.showsPlaylists {
            self.playlistsGrid(self.viewModel.tabPlaylists[tab] ?? [])
        } else {
            self.videosGrid(self.viewModel.tabVideos[tab] ?? detail.videos, tab: tab)
        }
    }

    @ViewBuilder
    private func videosGrid(_ videos: [YouTubeVideo], tab: YouTubeChannelTab) -> some View {
        if videos.isEmpty {
            ContentUnavailableView {
                Label(String(localized: "Nothing here yet"), systemImage: "play.rectangle")
            }
            .padding(.vertical, 40)
        } else {
            LazyVGrid(columns: Self.columns, spacing: 20) {
                ForEach(videos) { video in
                    // Shorts open in the vertical viewer seeded with this
                    // channel's shorts, starting on the tapped one; regular
                    // videos open the watch page.
                    NavigationLink(value: tab == .shorts
                        ? YouTubeRoute.creatorShorts(shorts: videos, startVideoId: video.videoId)
                        : YouTubeRoute.watch(video)
                    ) {
                        VideoCard(video: video)
                    }
                    .buttonStyle(.interactiveCard)
                }

                // Bottom sentinel: LazyVGrid only renders it once scrolled into
                // view, which fetches the next page (infinite scroll).
                if self.viewModel.hasMore(tab) {
                    ProgressView()
                        .controlSize(.small)
                        .task(id: self.viewModel.paginationTrigger) {
                            await self.viewModel.loadMore(tab)
                        }
                }
            }
        }
    }

    @ViewBuilder
    private func playlistsGrid(_ playlists: [YouTubePlaylist]) -> some View {
        if playlists.isEmpty {
            ContentUnavailableView {
                Label(String(localized: "No playlists"), systemImage: "list.and.film")
            }
            .padding(.vertical, 40)
        } else {
            LazyVGrid(columns: Self.columns, spacing: 20) {
                ForEach(playlists) { playlist in
                    NavigationLink(value: YouTubeRoute.playlist(playlistId: playlist.playlistId)) {
                        YouTubePlaylistCard(playlist: playlist)
                    }
                    .buttonStyle(.interactiveCard)
                }
            }
        }
    }

    private func header(for channel: YouTubeChannel) -> some View {
        HStack(spacing: 16) {
            CachedAsyncImage(
                url: channel.thumbnailURL,
                targetSize: CGSize(width: 80, height: 80)
            ) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Circle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
                    }
            }
            .frame(width: 80, height: 80)
            .clipShape(.circle)

            VStack(alignment: .leading, spacing: 4) {
                Text(channel.name)
                    .font(.title.bold())
                    .lineLimit(1)

                let meta = [channel.handle, channel.subscriberCountText].compactMap(\.self)
                if !meta.isEmpty {
                    Text(meta.joined(separator: " · "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if let description = channel.descriptionSnippet, !description.isEmpty {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)
        }
    }
}
