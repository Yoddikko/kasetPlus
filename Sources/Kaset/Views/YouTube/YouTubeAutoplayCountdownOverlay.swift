import SwiftUI

// MARK: - YouTubeAutoplayCountdownOverlay

/// YouTube-style "up next" countdown card, shown over the video surface after a
/// video finishes when autoplay is on: it names the next video and counts down
/// inside a ring the user can click to play now ("speed it up"), or cancel.
///
/// Reads the shared `YouTubePlayerService`, so both the inline watch view and the
/// floating window can host it; it renders nothing when no autoplay is pending.
struct YouTubeAutoplayCountdownOverlay: View {
    @Environment(YouTubePlayerService.self) private var youtubePlayer

    var body: some View {
        if let next = self.youtubePlayer.autoplayPendingVideo {
            self.card(next: next)
                .transition(.opacity)
        }
    }

    private func card(next: YouTubeVideo) -> some View {
        let total = YouTubePlayerService.autoplayCountdownSeconds
        let remaining = max(self.youtubePlayer.autoplayCountdownRemaining, 0)
        let fraction = CGFloat(remaining) / CGFloat(max(total, 1))

        return ZStack {
            Rectangle().fill(.black.opacity(0.62))

            VStack(spacing: 14) {
                Text("Up Next", comment: "Label above the autoplay countdown card")
                    .font(.system(size: 12, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.7))

                Text(next.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                // The ring counts down; clicking it plays the next video now.
                Button {
                    self.youtubePlayer.confirmAutoplayNow()
                } label: {
                    ZStack {
                        Circle().stroke(.white.opacity(0.25), lineWidth: 3)
                        Circle()
                            .trim(from: 0, to: fraction)
                            .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(remaining)")
                            .font(.system(size: 22, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white)
                    }
                    .frame(width: 62, height: 62)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(Text("Play now", comment: "Tooltip on the autoplay countdown play button"))

                Button {
                    self.youtubePlayer.cancelAutoplay()
                } label: {
                    Text("Cancel", comment: "Button to cancel autoplay to the next video")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 30)
                        .compatGlass(interactive: true, tint: nil, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(24)
            .frame(maxWidth: 440)
        }
        .animation(.linear(duration: 1), value: remaining)
    }
}
