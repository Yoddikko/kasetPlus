import Foundation

/// A section (tab) of a YouTube channel page — mirrors the tabs YouTube shows
/// (Home, Videos, Shorts, Live, Playlists).
enum YouTubeChannelTab: String, CaseIterable, Identifiable, Sendable {
    case home
    case videos
    case shorts
    case live
    case playlists

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .home: String(localized: "Home")
        case .videos: String(localized: "Videos")
        case .shorts: String(localized: "Shorts")
        case .live: String(localized: "Live")
        case .playlists: String(localized: "Playlists")
        }
    }

    /// Whether this tab holds playlists rather than videos.
    var showsPlaylists: Bool {
        self == .playlists
    }

    /// Innertube `browse` params that select this tab. `nil` for `.home`, which
    /// is the default landing tab already fetched by `getChannel`. These are the
    /// stable tokens YouTube uses for each channel tab (same values yt-dlp and
    /// NewPipe use), so no per-channel discovery is needed.
    var browseParams: String? {
        switch self {
        case .home: nil
        case .videos: "EgZ2aWRlb3PyBgQKAjoA"
        case .shorts: "EgZzaG9ydHPyBgUKA5oBAA=="
        case .live: "EgdzdHJlYW1z8gYECgJ6AA=="
        case .playlists: "EglwbGF5bGlzdHPyBgQKAkIA"
        }
    }
}

/// The content of a channel tab: either a grid of videos (Home/Videos/Shorts/
/// Live) or a grid of playlists (Playlists), plus a continuation token for the
/// next page when the tab has more.
enum YouTubeChannelTabContent: Sendable {
    case videos([YouTubeVideo], continuation: String?)
    case playlists([YouTubePlaylist], continuation: String?)
}
