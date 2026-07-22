import Foundation
import Observation
import os

// MARK: - UploadsFilter

/// Filter options for the Uploads view.
enum UploadsFilter: String, CaseIterable, Identifiable, Hashable, FilterOption {
    case all = "All"
    case playlists = "Playlists"
    case albums = "Albums"
    case artists = "Artists"

    var id: String { self.rawValue }

    var displayName: String {
        switch self {
        case .all: String(localized: "All")
        case .playlists: String(localized: "Playlists")
        case .albums: String(localized: "Albums")
        case .artists: String(localized: "Artists")
        }
    }
}

@MainActor
@Observable
final class UploadsViewModel {
    private(set) var loadingState: LoadingState = .idle

    /// Content from the uploads landing page — used for the "All" view.
    /// Web app does NOT show artists in "All", only playlists + albums.
    private var landingPlaylists: [Playlist] = []

    /// Dedicated endpoint data — loaded lazily when a specific filter is selected.
    private(set) var albums: [Album] = []
    private(set) var artists: [Artist] = []
    private(set) var playlists: [Playlist] = []
    private var albumsLoaded = false
    private var playlistsLoaded = false
    private var artistsLoaded = false

    /// Pagination state for albums.
    private var albumsContinuationToken: String?
    private(set) var albumsHasMore = false
    private(set) var isLoadingMoreAlbums = false

    /// Filters whose dedicated endpoint is currently being fetched.
    private(set) var loadingFilters: Set<UploadsFilter> = []

    var selectedFilter: UploadsFilter = .all {
        didSet {
            guard oldValue != self.selectedFilter, self.loadingState == .loaded else { return }
            // Immediately set loading state so the view shows a spinner instead of stale/empty data
            if self.needsLoading(for: self.selectedFilter) {
                self.loadingFilters.insert(self.selectedFilter)
            }
            self.ensureFilterLoaded()
        }
    }

    private func needsLoading(for filter: UploadsFilter) -> Bool {
        switch filter {
        case .all: return false
        case .playlists: return !self.playlistsLoaded
        case .albums: return !self.albumsLoaded
        case .artists: return !self.artistsLoaded
        }
    }

    /// Items for the current filter.
    var filteredItems: [UploadsItem] {
        switch self.selectedFilter {
        case .all:
            return self.landingPlaylists.map { UploadsItem.playlist($0) }
        case .playlists:
            self.ensureFilterLoaded()
            return self.playlists.map { UploadsItem.playlist($0) }
        case .albums:
            self.ensureFilterLoaded()
            return self.albums.map { UploadsItem.album($0) }
        case .artists:
            self.ensureFilterLoaded()
            return self.artists.map { UploadsItem.artist($0) }
        }
    }

    /// Whether the current filter's data is still loading.
    var isFilterLoading: Bool {
        self.selectedFilter != .all && self.loadingFilters.contains(self.selectedFilter)
    }

    let client: any YTMusicClientProtocol
    private let logger = DiagnosticsLogger.api

    init(client: any YTMusicClientProtocol) {
        self.client = client
    }

    func load() async {
        guard self.loadingState != .loading else { return }
        self.loadingState = .loading
        self.logger.info("Loading uploads")

        do {
            let landing = try await self.client.getUploadsLandingContent()
            self.landingPlaylists = landing.playlists

            self.loadingState = .loaded
            self.logger.info("Uploads loaded: \(self.landingPlaylists.count) items")
        } catch {
            self.logger.error("Failed to load uploads: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    private func ensureFilterLoaded() {
        guard self.loadingState == .loaded else { return }

        switch self.selectedFilter {
        case .albums where !self.albumsLoaded:
            self.albumsLoaded = true
            Task {
                let (albums, token) = (try? await self.client.getUploadedReleasesContinuation()) ?? ([], nil)
                if !albums.isEmpty {
                    self.albums = albums
                }
                self.albumsContinuationToken = token
                self.albumsHasMore = token != nil
                self.loadingFilters.remove(.albums)
                self.logger.info("Uploads albums loaded: \(self.albums.count), hasMore=\(token != nil)")
            }
        case .playlists where !self.playlistsLoaded:
            self.playlistsLoaded = true
            Task {
                let result = try? await self.client.getUploadedPlaylists()
                if let r = result, !r.isEmpty {
                    self.playlists = r
                }
                self.loadingFilters.remove(.playlists)
                self.logger.info("Uploads playlists loaded: \(self.playlists.count)")
            }
        case .artists where !self.artistsLoaded:
            self.artistsLoaded = true
            Task {
                let result = try? await self.client.getUploadedArtists()
                if let r = result, !r.isEmpty {
                    self.artists = r
                }
                self.loadingFilters.remove(.artists)
                self.logger.info("Uploads artists loaded: \(self.artists.count)")
            }
        default:
            break
        }
    }

    /// Loads the next page of albums via continuation.
    func loadMoreAlbums() async {
        guard self.selectedFilter == .albums,
              self.albumsHasMore,
              let token = self.albumsContinuationToken,
              !self.isLoadingMoreAlbums
        else { return }
        self.isLoadingMoreAlbums = true
        let (moreAlbums, nextToken) = (try? await self.client.getUploadedReleasesContinuation(token: token)) ?? ([], nil)
        if !moreAlbums.isEmpty {
            self.albums.append(contentsOf: moreAlbums)
        }
        self.albumsContinuationToken = nextToken
        self.albumsHasMore = nextToken != nil
        self.isLoadingMoreAlbums = false
    }
}

// MARK: - UploadsItem

enum UploadsItem: Identifiable {
    case playlist(Playlist)
    case album(Album)
    case artist(Artist)

    var id: String {
        switch self {
        case let .playlist(p): "playlist-\(p.id)"
        case let .album(a): "album-\(a.id)"
        case let .artist(a): "artist-\(a.id)"
        }
    }
}
