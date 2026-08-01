import SwiftUI

// MARK: - VideoRowView

/// Horizontal list row for a YouTube video (search results, related lists).
struct VideoRowView: View {
    let video: YouTubeVideo

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VideoThumbnailView(video: self.video, targetSize: CGSize(width: 160, height: 90))
                .frame(width: 160)

            VStack(alignment: .leading, spacing: 3) {
                let displayTitle = DearrowCache.shared.displayTitle(
                    for: self.video.videoId, original: self.video.title)
                Text(displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    // Full title as a hover tooltip when truncated.
                    .help(displayTitle)

                if let channelName = self.video.channelName {
                    Text(channelName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                let meta = [self.video.viewCountText, self.video.publishedText].compactMap(\.self)
                if !meta.isEmpty {
                    Text(meta.joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .onAppear {
            DearrowCache.shared.fetchOneIfNeeded(videoId: self.video.videoId)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - ChannelRowView

/// List row for a YouTube channel (search results).
struct ChannelRowView: View {
    let channel: YouTubeChannel

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(
                url: self.channel.thumbnailURL,
                targetSize: CGSize(width: 48, height: 48)
            ) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Circle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "person.fill")
                            .foregroundStyle(.tertiary)
                    }
            }
            .frame(width: 48, height: 48)
            .clipShape(.circle)

            VStack(alignment: .leading, spacing: 3) {
                Text(self.channel.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                let meta = [self.channel.handle, self.channel.subscriberCountText]
                    .compactMap(\.self)
                if !meta.isEmpty {
                    Text(meta.joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let snippet = self.channel.descriptionSnippet {
                    Text(snippet)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - YouTubePlaylistRowView

/// List row for a YouTube playlist (search results, library lists).
struct YouTubePlaylistRowView: View {
    let playlist: YouTubePlaylist

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    CachedAsyncImage(
                        url: self.playlist.thumbnailURL,
                        targetSize: CGSize(width: 160, height: 90)
                    ) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle()
                            .fill(.quaternary)
                            .overlay {
                                Image(systemName: "list.and.film")
                                    .foregroundStyle(.tertiary)
                            }
                    }
                }
                .frame(width: 160)
                .clipShape(.rect(cornerRadius: 8))
                .overlay(alignment: .bottomTrailing) {
                    if let videoCountText = self.playlist.videoCountText {
                        Text(videoCountText)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.75), in: .rect(cornerRadius: 4))
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                }
                .stackedPoster()
                // Clamp the stack slivers to the poster width; otherwise the
                // flexible sliver strip stretches across the whole row.
                .frame(width: 160)

            VStack(alignment: .leading, spacing: 3) {
                Text(self.playlist.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if let channelName = self.playlist.channelName {
                    Text(channelName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text("Playlist", comment: "Kind label on playlist rows")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - YouTubePlaylistCard

/// Grid card for a YouTube playlist: 16:9 thumbnail with a count badge,
/// title, and channel line (matches `VideoCard`'s layout).
struct YouTubePlaylistCard: View {
    let playlist: YouTubePlaylist

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    CachedAsyncImage(
                        url: self.playlist.thumbnailURL,
                        targetSize: CGSize(width: 320, height: 180)
                    ) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle()
                            .fill(.quaternary)
                            .overlay {
                                Image(systemName: "list.and.film")
                                    .font(.system(size: 24))
                                    .foregroundStyle(.tertiary)
                            }
                    }
                }
                .clipShape(.rect(cornerRadius: 8))
                .overlay(alignment: .bottomTrailing) {
                    if let videoCountText = self.playlist.videoCountText {
                        Text(videoCountText)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.75), in: .rect(cornerRadius: 4))
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                }
                .stackedPoster()

            VStack(alignment: .leading, spacing: 3) {
                Text(self.playlist.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if let channelName = self.playlist.channelName {
                    Text(channelName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Stacked Poster (playlists)

/// The layered "stack" cue for playlist posters: two cards peeking in a thin
/// strip *above* the poster, like a stack of thumbnails. Only used on playlist
/// grids/lists (uniform heights), not on mix video cards which live in mixed
/// rails where the extra height would misalign them.
private struct StackedPosterBackground: ViewModifier {
    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                self.sliver(inset: 18, height: 7, shade: 0.38)
                self.sliver(inset: 9, height: 4, shade: 0.55)
            }
            .frame(height: 7)
            content
        }
    }

    private func sliver(inset: CGFloat, height: CGFloat, shade: Double) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(Color(white: shade))
            .frame(height: height)
            .padding(.horizontal, inset)
    }
}

extension View {
    /// Wraps a 16:9 poster in the playlist "stack" look (cards peeking above).
    func stackedPoster() -> some View {
        self.modifier(StackedPosterBackground())
    }
}
