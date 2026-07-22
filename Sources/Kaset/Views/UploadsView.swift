import SwiftUI

struct UploadsView: View {
    @State var viewModel: UploadsViewModel
    @State private var navigationPath = NavigationPath()
    @Environment(PlayerService.self) private var playerService
    @Environment(AuthService.self) private var authService
    @State private var networkMonitor = NetworkMonitor.shared

    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 24),
    ]

    var body: some View {
        NavigationStack(path: self.$navigationPath) {
            VStack(spacing: 0) {
                self.filterChips
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)

                Divider()

                if !self.networkMonitor.isConnected {
                    self.offlineView
                } else {
                    self.contentView
                }
            }
            .localizedNavigationTitle("Uploads")
            .navigationDestinations(
                client: self.viewModel.client,
                playerBarNavigationAction: self.playerBarNavigationAction
            )
            .playerBarMusicNavigation(path: self.$navigationPath)
            .task { await self.viewModel.load() }
        }
        .playerBarMusicNavigation(path: self.$navigationPath)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerBar()
                .playerBarMusicNavigation(path: self.$navigationPath)
        }
    }

    private var playerBarNavigationAction: PlayerBarNavigationAction {
        PlayerBarNavigationAction(
            openArtist: { self.navigationPath.append($0) },
            openAlbum: { self.navigationPath.append($0) }
        )
    }

    // MARK: - Content

    @ViewBuilder
    private var contentView: some View {
        switch self.viewModel.loadingState {
        case .idle, .loading, .loadingMore:
            LoadingView(String(localized: "Loading uploads..."))
        case .loaded:
            if self.viewModel.isFilterLoading {
                LoadingView(String(localized: "Loading..."))
            } else if self.viewModel.filteredItems.isEmpty {
                self.emptyStateView
            } else {
                ScrollView {
                    LazyVGrid(columns: self.columns, spacing: 24) {
                        ForEach(Array(self.viewModel.filteredItems.enumerated()), id: \.element.id) { index, item in
                            switch item {
                            case let .playlist(playlist):
                                self.playlistCard(playlist)
                            case let .album(album):
                                self.albumCard(album)
                            case let .artist(artist):
                                self.artistCard(artist)
                            }
                        }

                        // Load more trigger for albums
                        if self.viewModel.selectedFilter == .albums, self.viewModel.albumsHasMore {
                            if self.viewModel.isLoadingMoreAlbums {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 24)
                            } else {
                                Color.clear
                                    .frame(height: 1)
                                    .onAppear {
                                        Task { await self.viewModel.loadMoreAlbums() }
                                    }
                            }
                        }
                    }
                    .padding(24)
                }
            }
        case let .error(error):
            ErrorView(error: error) {
                Task { await self.viewModel.load() }
            }
        }
    }

    private var filterChips: some View {
        FilterChipBar(
            filters: UploadsFilter.allCases,
            selection: self.$viewModel.selectedFilter
        )
    }

    private func playlistCard(_ playlist: Playlist) -> some View {
        Button {
            self.navigationPath.append(playlist)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                CachedAsyncImage(
                    url: playlist.thumbnailURL?.highQualityThumbnailURL,
                    targetSize: CGSize(width: 160, height: 160)
                ) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(.quaternary)
                        .overlay { Image(systemName: "music.note.list").foregroundStyle(.secondary) }
                }
                .frame(width: 160, height: 160)
                .clipShape(.rect(cornerRadius: 6))

                Text(playlist.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            .frame(width: 160)
        }
        .buttonStyle(.plain)
    }

    private func albumCard(_ album: Album) -> some View {
        Button {
            let playlist = Playlist(
                id: album.id,
                title: album.title,
                description: nil,
                thumbnailURL: album.thumbnailURL,
                trackCount: album.trackCount,
                author: Artist.inline(name: album.artistsDisplay, namespace: "album-artist")
            )
            self.navigationPath.append(playlist)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                CachedAsyncImage(
                    url: album.thumbnailURL?.highQualityThumbnailURL,
                    targetSize: CGSize(width: 160, height: 160)
                ) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(.quaternary)
                        .overlay { Image(systemName: "square.stack").foregroundStyle(.secondary) }
                }
                .frame(width: 160, height: 160)
                .clipShape(.rect(cornerRadius: 6))

                Text(album.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            .frame(width: 160)
        }
        .buttonStyle(.plain)
    }

    private func artistCard(_ artist: Artist) -> some View {
        Button {
            self.navigationPath.append(artist)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                CachedAsyncImage(
                    url: artist.thumbnailURL?.highQualityThumbnailURL,
                    targetSize: CGSize(width: 160, height: 160)
                ) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                        .clipShape(.circle)
                } placeholder: {
                    Circle().fill(.quaternary)
                        .overlay { Image(systemName: "person").foregroundStyle(.secondary) }
                }
                .frame(width: 80, height: 80)
                .frame(maxWidth: .infinity)

                Text(artist.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .frame(width: 120)
        }
        .buttonStyle(.plain)
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray.and.arrow.up")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No uploads yet", comment: "Empty state for uploads page")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var offlineView: some View {
        ErrorView(
            title: String(localized: "No Connection"),
            message: String(localized: "Please check your internet connection and try again.")
        ) { Task { await self.viewModel.load() } }
    }
}
