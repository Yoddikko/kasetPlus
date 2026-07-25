import SwiftUI

// MARK: - VideoCard

/// Grid card for a YouTube video: 16:9 thumbnail with duration badge,
/// title, and channel/meta lines.
struct VideoCard: View {
    let video: YouTubeVideo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VideoThumbnailView(video: self.video)

            VStack(alignment: .leading, spacing: 3) {
                Text(DearrowCache.shared.displayTitle(
                    for: self.video.videoId, original: self.video.title))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    // Always reserve two lines so 1- vs 2-line titles don't make
                    // cards in a row different heights (they're top-aligned).
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                    .id("dearrow-\(self.video.videoId)-\(DearrowCache.shared.hasDearrow(for: self.video.videoId))")

                if let channelName = self.video.channelName {
                    Text(channelName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let metaText = self.metaText {
                    Text(metaText)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onAppear {
            DearrowCache.shared.fetchOneIfNeeded(videoId: self.video.videoId)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(self.accessibilityText)
    }

    private var metaText: String? {
        let parts = [self.video.viewCountText, self.video.publishedText].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var accessibilityText: String {
        var parts = [self.video.title]
        if let channelName = self.video.channelName {
            parts.append(channelName)
        }
        if let metaText = self.metaText {
            parts.append(metaText)
        }
        if let percent = self.video.watchedPercent {
            parts.append(String(
                localized: "Watched \(percent)%",
                comment: "Accessibility label for a partially-watched video card"
            ))
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - VideoThumbnailView

/// 16:9 video thumbnail with a duration (or LIVE) badge.
struct VideoThumbnailView: View {
    let video: YouTubeVideo
    var targetSize = CGSize(width: 320, height: 180)

    var body: some View {
        // A Mix reads as the video's own poster wearing the shared "stack" cue
        // (like a playlist), plus a Mix badge — mirroring YouTube.
        self.thumbnail.stackedPoster(self.video.mixPlaylistId != nil)
    }

    private var thumbnail: some View {
        CachedAsyncImage(
            url: self.video.thumbnailURL,
            targetSize: self.targetSize
        ) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            Rectangle()
                .fill(.quaternary)
                .overlay {
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .overlay(alignment: .bottom) {
            if let percent = self.video.watchedPercent {
                self.watchedProgressBar(percent: percent)
            }
        }
        .clipShape(.rect(cornerRadius: 8))
        .overlay(alignment: .bottomTrailing) {
            self.badge
        }
        .overlay(alignment: .topLeading) {
            if self.video.isMembersOnly {
                self.membersBadge
            }
        }
    }


    /// "Members only" badge for channel-membership-restricted videos (green,
    /// like YouTube), mirroring the LIVE/duration badge treatment.
    private var membersBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "star.fill")
                .font(.system(size: 8))
            Text("Members only", comment: "Badge on channel-members-only videos")
                .font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Color(red: 0.18, green: 0.55, blue: 0.34), in: .rect(cornerRadius: 4))
        .foregroundStyle(.white)
        .padding(6)
    }

    /// Thin red resume-progress bar pinned flush to the thumbnail's bottom edge.
    /// Clipped by the parent's rounded corners. Exposed as its own labeled
    /// accessibility element so consumers that combine children (the related
    /// rail and list rows) announce the watched percent; `VideoCard` overrides
    /// this with its own curated label, which already includes it.
    @ViewBuilder
    private func watchedProgressBar(percent: Int) -> some View {
        let fraction = CGFloat(min(max(percent, 0), 100)) / 100
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(.white.opacity(0.3))
            Rectangle()
                .fill(.red)
                .scaleEffect(x: fraction, anchor: .leading)
        }
        .frame(height: 3)
        .accessibilityElement()
        .accessibilityLabel(Text(
            "Watched \(percent)%",
            comment: "Accessibility label describing how much of a video has been watched"
        ))
    }

    @ViewBuilder
    private var badge: some View {
        if self.video.isLive {
            Text("LIVE", comment: "Badge on live stream thumbnails")
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.red.opacity(0.9), in: .rect(cornerRadius: 4))
                .foregroundStyle(.white)
                .padding(6)
        } else if self.video.mixPlaylistId != nil {
            HStack(spacing: 3) {
                Image(systemName: "play.fill")
                    .font(.system(size: 7, weight: .bold))
                Text("Mix", comment: "Badge on an auto-generated Mix (radio) card")
                    .font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.black.opacity(0.75), in: .rect(cornerRadius: 4))
            .foregroundStyle(.white)
            .padding(6)
        } else if let lengthText = self.video.lengthText {
            Text(lengthText)
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.black.opacity(0.75), in: .rect(cornerRadius: 4))
                .foregroundStyle(.white)
                .padding(6)
        }
    }
}

// MARK: - Stacked Poster (Mixes & Playlists)

/// The layered "stack" cue YouTube uses for collections: two subtle cards
/// peeking above the poster's top edge. Shared by Mixes and playlists so both
/// read the same, at the app's 16:9 poster proportions and rounded corners.
private struct StackedPosterBackground: ViewModifier {
    func body(content: Content) -> some View {
        // The stacked "cards" peek in a reserved strip *above* the poster (never
        // behind it), so they can't bleed through a missing thumbnail, can't
        // draw a frame around the poster, and can't be clipped by a rail. The
        // slivers carry no width — as siblings they fill the poster's width and
        // are inset, staying centred and narrower than the poster.
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
    /// Wraps a 16:9 poster in YouTube's collection "stack" look. Pass `false`
    /// to render the poster unchanged (non-collection cards).
    @ViewBuilder
    func stackedPoster(_ show: Bool = true) -> some View {
        if show {
            self.modifier(StackedPosterBackground())
        } else {
            self
        }
    }
}

#Preview {
    VideoCard(
        video: YouTubeVideo(
            videoId: "preview",
            title: "A Very Interesting Video About Swift Concurrency and Other Things",
            channelName: "Apple Developer",
            lengthText: "28:01",
            viewCountText: "29K views",
            publishedText: "1 year ago",
            watchedPercent: 65
        )
    )
    .frame(width: 320)
    .padding()
}
