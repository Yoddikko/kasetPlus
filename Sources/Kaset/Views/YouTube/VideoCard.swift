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
                Text(self.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    // Always reserve two lines so 1- vs 2-line titles don't make
                    // cards in a row different heights (they're top-aligned).
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                    // Long titles truncate to two lines — surface the full title
                    // as a native hover tooltip.
                    .help(self.displayTitle)
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

    private var displayTitle: String {
        DearrowCache.shared.displayTitle(for: self.video.videoId, original: self.video.title)
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
        // A Mix reads as the video's own 16:9 poster plus the "Mix" badge — no
        // extra "stack" chrome, so mix cards stay the same size as video cards
        // and line up in mixed rails/grids.
        self.thumbnail
    }

    private var thumbnail: some View {
        // Anchor a strict 16:9 box (Color.clear) and fill it with the image,
        // so square covers (YouTube-Music mix art) are cropped to 16:9 instead
        // of stretching the card. `.aspectRatio` on the image alone is ignored
        // because CachedAsyncImage adopts the source's own aspect.
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
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
            }
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
