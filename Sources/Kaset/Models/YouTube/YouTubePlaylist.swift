import Foundation

// MARK: - YouTubePlaylist

/// A regular YouTube playlist as it appears in search results and library lists.
struct YouTubePlaylist: Identifiable, Hashable {
    let playlistId: String
    let title: String
    let channelName: String?
    /// Display video count, e.g. "120 videos".
    let videoCountText: String?
    let thumbnailURL: URL?
    /// First video, used for quick-play.
    let firstVideoId: String?

    var id: String {
        self.playlistId
    }

    init(
        playlistId: String,
        title: String,
        channelName: String? = nil,
        videoCountText: String? = nil,
        thumbnailURL: URL? = nil,
        firstVideoId: String? = nil
    ) {
        self.playlistId = playlistId
        self.title = title
        self.channelName = channelName
        self.videoCountText = videoCountText
        self.thumbnailURL = thumbnailURL
        self.firstVideoId = firstVideoId
    }

    /// The watch target for opening this playlist like YouTube does: play the
    /// first video with the playlist as context, so the watch page's up-next
    /// panel shows the playlist queue. `nil` when the first video is unknown
    /// (fall back to the playlist list page).
    var watchTarget: YouTubeVideo? {
        guard let firstVideoId else { return nil }
        return YouTubeVideo(
            videoId: firstVideoId,
            title: self.title,
            channelName: self.channelName,
            thumbnailURL: self.thumbnailURL,
            mixPlaylistId: self.playlistId
        )
    }
}

// MARK: - YouTubePlaylistDetail

/// A playlist page: metadata plus its videos.
struct YouTubePlaylistDetail: Hashable {
    let playlist: YouTubePlaylist
    let videos: [YouTubeVideo]
}
