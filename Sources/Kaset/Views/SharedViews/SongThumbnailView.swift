import Foundation
import SwiftUI

// MARK: - SongThumbnailView

/// Displays a song's thumbnail.
/// Falls back to YouTube's public video thumbnail (`i.ytimg.com`) when the API
/// does not provide one.  Does NOT use the `failedPrimaryKey` fallback mechanism
/// — every render tries the primary URL first so transient load failures do not
/// permanently switch to the 16:9 fallback image.
struct SongThumbnailView: View {
    let song: Song
    var size: CGFloat = 48
    var cornerRadius: CGFloat = 6

    private var primaryURL: URL? {
        self.song.thumbnailURL
    }

    private var fallbackURL: URL? {
        self.song.fallbackThumbnailURL
    }

    private var targetSize: CGSize {
        let dimension = max(self.size, 1)
        return CGSize(width: dimension, height: dimension)
    }

    var body: some View {
        CachedAsyncImage(url: self.primaryURL ?? self.fallbackURL, targetSize: self.targetSize) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            Rectangle()
                .fill(.quaternary)
                .overlay {
                    Image(systemName: "music.note")
                        .foregroundStyle(.secondary)
                }
        }
        .frame(width: self.size, height: self.size)
        .clipShape(.rect(cornerRadius: self.cornerRadius))
    }
}
