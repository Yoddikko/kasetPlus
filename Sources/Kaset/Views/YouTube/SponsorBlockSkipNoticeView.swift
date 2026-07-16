import SwiftUI

/// Native feedback shown over the video after SponsorBlock skips a segment.
/// Keeping this outside the watch-page DOM makes it visible even while Kaset
/// hides all of YouTube's chrome.
struct SponsorBlockSkipNoticeOverlay: View {
    @Environment(YouTubePlayerService.self) private var youtubePlayer

    var body: some View {
        Group {
            if let notice = self.youtubePlayer.sponsorSkipNotice {
                SponsorBlockSkipNoticeView(
                    notice: notice,
                    onUndo: {
                        HapticService.playback()
                        self.youtubePlayer.undoSponsorBlockSkip()
                    }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: self.youtubePlayer.sponsorSkipNotice?.id)
    }
}

private struct SponsorBlockSkipNoticeView: View {
    let notice: SponsorSkipNotice
    let onUndo: () -> Void

    var body: some View {
        CompatGlassContainer(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(self.notice.segment.color)

                HStack(spacing: 4) {
                    Text("Skipped", comment: "SponsorBlock skip notice prefix")
                    Text(self.notice.segment.localizedCategoryName)
                        .fontWeight(.semibold)
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

                Button(action: self.onUndo) {
                    Label {
                        Text("Undo", comment: "Undo a SponsorBlock skip")
                    } icon: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .compatGlass(
                    interactive: true,
                    tint: self.notice.segment.color.opacity(0.18),
                    in: .capsule
                )
                .help(Text("Return to the skipped segment", comment: "SponsorBlock undo button help"))
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .compatGlass(in: .capsule)
            .shadow(color: .black.opacity(0.28), radius: 12, y: 5)
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(
            "Skipped \(self.notice.segment.localizedCategoryName)",
            comment: "SponsorBlock skip notice accessibility label"
        ))
    }
}
