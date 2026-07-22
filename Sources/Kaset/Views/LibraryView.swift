import SwiftUI

// MARK: - LibraryFilter

/// Filter options for the Library view.
enum LibraryFilter: String, CaseIterable, Identifiable, Hashable, FilterOption {
    case all = "All"
    case playlists = "Playlists"
    case albums = "Albums"
    case artists = "Artists"
    case podcasts = "Podcasts"

    var id: String {
        self.rawValue
    }

    var displayName: String {
        switch self {
        case .all:
            String(localized: "All")
        case .playlists:
            String(localized: "Playlists")
        case .albums:
            String(localized: "Albums")
        case .artists:
            String(localized: "Artists")
        case .podcasts:
            String(localized: "Podcasts")
        }
    }
}

// MARK: - LibraryView

/// Library view displaying user's playlists and podcast shows.
struct LibraryView: View {
    @State var viewModel: LibraryViewModel
    @Environment(PlayerService.self) private var playerService
    @Environment(FavoritesManager.self) private var favoritesManager
    @Environment(\.usesLegacyMacOS15UI) private var usesLegacyMacOS15UI
    @State private var networkMonitor = NetworkMonitor.shared

    @State private var navigationPath = NavigationPath()
    @State private var selectedFilter: LibraryFilter = .all

    private let libraryItemSize: CGFloat = 160
    private let libraryItemSpacing: CGFloat = 18
    private let libraryItemCardHeight: CGFloat = 222

    var body: some View {
        NavigationStack(path: self.$navigationPath) {
            VStack(spacing: 0) {
                self.filterChips
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)

                Divider()

                Group {
                    if !self.networkMonitor.isConnected {
                        ErrorView(
                            title: String(localized: "No Connection"),
                            message: String(localized: "Please check your internet connection and try again.")
                        ) {
                            Task { await self.viewModel.refresh() }
                        }
                    } else {
                        switch self.viewModel.loadingState {
                        case .idle, .loading:
                            LoadingView(String(localized: "Loading your library..."))
                        case .loaded, .loadingMore:
                            self.contentView
                        case let .error(error):
                            ErrorView(error: error) {
                                Task { await self.viewModel.refresh() }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .localizedNavigationTitle("Library")
            .navigationDestination(for: Playlist.self) { playlist in
                if !self.usesLegacyMacOS15UI, #available(macOS 26.0, *) {
                    PlaylistDetailView(
                        playlist: playlist,
                        viewModel: PlaylistDetailViewModel(
                            playlist: playlist,
                            client: self.viewModel.client
                        ),
                        playerBarNavigationAction: self.playerBarNavigationAction
                    )
                } else {
                    SimplePlaylistDetailView(
                        playlist: playlist,
                        viewModel: PlaylistDetailViewModel(
                            playlist: playlist,
                            client: self.viewModel.client
                        ),
                        playerBarNavigationAction: self.playerBarNavigationAction
                    )
                }
            }
            .navigationDestination(for: Artist.self) { artist in
                ArtistDetailView(
                    artist: artist,
                    viewModel: ArtistDetailViewModel(
                        artist: artist,
                        client: self.viewModel.client,
                        libraryViewModel: self.viewModel
                    ),
                    playerBarNavigationAction: self.playerBarNavigationAction
                )
            }
            .navigationDestination(for: TopSongsDestination.self) { destination in
                TopSongsView(
                    viewModel: TopSongsViewModel(
                        destination: destination,
                        client: self.viewModel.client
                    )
                )
            }
            .navigationDestination(for: PodcastShow.self) { show in
                PodcastShowView(show: show, client: self.viewModel.client)
            }
            .playerBarMusicNavigation(path: self.$navigationPath)
        }
        .playerBarMusicNavigation(path: self.$navigationPath)
        .environment(self.viewModel)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerBar()
                .playerBarMusicNavigation(path: self.$navigationPath)
        }
        .task {
            if self.viewModel.loadingState == .idle {
                await self.viewModel.load()
            }
            await self.viewModel.reloadIfNeededOnActivation()
        }
        .task(id: "\(self.navigationPath.count)-\(self.viewModel.activationReloadGeneration)") {
            guard self.navigationPath.isEmpty else { return }
            await self.viewModel.reloadIfNeededOnActivation()
        }
        .refreshable {
            await self.viewModel.refresh()
        }
        .popsNavigationStackOnSidebarReselect(path: self.$navigationPath, for: .library)
    }

    private var playerBarNavigationAction: PlayerBarNavigationAction {
        PlayerBarNavigationAction(
            openArtist: { self.navigationPath.append($0) },
            openAlbum: { self.navigationPath.append($0) }
        )
    }

    // MARK: - Views

    private var contentView: some View {
        ScrollView {
            self.libraryGrid
                .padding(.vertical, 20)
        }
        .contentMargins(.horizontal, DetailContentLayout.horizontalInset, for: .scrollContent)
    }

    private var filterChips: some View {
        FilterChipBar(
            filters: LibraryFilter.allCases,
            selection: self.$selectedFilter
        )
    }

    /// All library items combined and filtered.
    private var filteredItems: [LibraryItem] {
        var items: [LibraryItem] = []

        switch self.selectedFilter {
        case .all:
            items = self.viewModel.playlists.map { .playlist($0) }
                + self.viewModel.artists.map { .artist($0) }
                + self.viewModel.podcastShows.map { .podcast($0) }
        case .playlists:
            items = self.viewModel.playlists.map { .playlist($0) }
        case .albums:
            items = self.viewModel.playlists.filter { $0.id.hasPrefix("MPRE") || $0.id.hasPrefix("OLAK") }.map { .playlist($0) }
        case .artists:
            items = self.viewModel.artists.map { .artist($0) }
        case .podcasts:
            items = self.viewModel.podcastShows.map { .podcast($0) }
        }

        return items
    }

    @ViewBuilder
    private var libraryGrid: some View {
        if self.filteredItems.isEmpty {
            self.emptyStateView
        } else {
            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: self.libraryItemSize, maximum: 200), spacing: self.libraryItemSpacing),
            ], spacing: 24) {
                ForEach(self.filteredItems) { item in
                    switch item {
                    case let .playlist(playlist):
                        self.playlistCard(playlist)
                    case let .artist(artist):
                        self.artistCard(artist)
                    case let .podcast(show):
                        self.podcastCard(show)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.2x2")
                .font(.largeTitle)
                .foregroundStyle(.secondary)

            Text(self.emptyStateTitle)
                .font(.headline)
                .foregroundStyle(.secondary)

            Text(self.emptyStateMessage)
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
    }

    private var emptyStateTitle: String {
        switch self.selectedFilter {
        case .all:
            String(localized: "Your library is empty")
        case .playlists:
            String(localized: "No playlists yet")
        case .albums:
            String(localized: "No albums yet")
        case .artists:
            String(localized: "No artists yet")
        case .podcasts:
            String(localized: "No podcasts yet")
        }
    }

    private var emptyStateMessage: String {
        switch self.selectedFilter {
        case .all:
            String(localized: "Save playlists, follow artists, and subscribe to podcasts on YouTube Music to see them here.")
        case .playlists:
            String(localized: "Create or save playlists on YouTube Music to see them here.")
        case .albums:
            String(localized: "Save albums on YouTube Music to see them here.")
        case .artists:
            String(localized: "Follow artists on YouTube Music to see them here.")
        case .podcasts:
            String(localized: "Subscribe to podcasts on YouTube Music to see them here.")
        }
    }

    private func playlistCard(_ playlist: Playlist) -> some View {
        Button {
            self.navigationPath.append(playlist)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                // Thumbnail
                CachedAsyncImage(url: playlist.thumbnailURL?.highQualityThumbnailURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "music.note.list")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        }
                }
                .frame(width: self.libraryItemSize, height: self.libraryItemSize)
                .clipShape(.rect(cornerRadius: 8))

                // Title
                Text(playlist.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: self.libraryItemSize, alignment: .topLeading)

                // Track count
                if let count = playlist.trackCount {
                    Text("\(count) songs", comment: "Playlist track count")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: self.libraryItemSize, alignment: .leading)
                }
            }
            .frame(width: self.libraryItemSize, height: self.libraryItemCardHeight, alignment: .topLeading)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if playlist.canDelete {
                Button(role: .destructive) {
                    SongActionsHelper.confirmDeletePlaylist(
                        playlist,
                        client: self.viewModel.client,
                        libraryViewModel: self.viewModel
                    )
                } label: {
                    Label(String(localized: "Delete Playlist…"), systemImage: "trash")
                }
            }
        }
    }

    private func podcastCard(_ show: PodcastShow) -> some View {
        Button {
            self.navigationPath.append(show)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                // Thumbnail
                CachedAsyncImage(url: show.thumbnailURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "mic.fill")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        }
                }
                .frame(width: self.libraryItemSize, height: self.libraryItemSize)
                .clipShape(.rect(cornerRadius: 8))

                // Title
                Text(show.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: self.libraryItemSize, alignment: .topLeading)

                // Author
                if let author = show.author {
                    Text(author)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: self.libraryItemSize, alignment: .leading)
                }
            }
            .frame(width: self.libraryItemSize, height: self.libraryItemCardHeight, alignment: .topLeading)
        }
        .buttonStyle(.plain)
        .contextMenu {
            FavoritesContextMenu.menuItem(for: show, manager: self.favoritesManager)
        }
    }

    private func artistCard(_ artist: Artist) -> some View {
        Button {
            self.navigationPath.append(artist)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                CachedAsyncImage(url: artist.thumbnailURL?.highQualityThumbnailURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Circle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "person.fill")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        }
                }
                .frame(width: self.libraryItemSize, height: self.libraryItemSize)
                .clipShape(Circle())

                Text(artist.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: self.libraryItemSize, alignment: .top)

                Text(String(localized: "Artist"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: self.libraryItemSize)
            }
            .frame(width: self.libraryItemSize, height: self.libraryItemCardHeight, alignment: .top)
        }
        .buttonStyle(.plain)
        .contextMenu {
            FavoritesContextMenu.menuItem(for: artist, manager: self.favoritesManager)
            ShareContextMenu.menuItem(for: artist)
        }
    }
}

// MARK: - LibraryItem

/// Represents a library item that can be a playlist, artist, or podcast show.
enum LibraryItem: Identifiable {
    case playlist(Playlist)
    case artist(Artist)
    case podcast(PodcastShow)

    var id: String {
        switch self {
        case let .playlist(playlist):
            "playlist-\(playlist.id)"
        case let .artist(artist):
            "artist-\(artist.id)"
        case let .podcast(show):
            "podcast-\(show.id)"
        }
    }
}

#Preview {
    let authService = AuthService()
    let client = YTMusicClient(authService: authService, webKitManager: .shared)
    LibraryView(viewModel: LibraryViewModel(client: client))
        .environment(PlayerService())
        .environment(FavoritesManager.shared)
}
