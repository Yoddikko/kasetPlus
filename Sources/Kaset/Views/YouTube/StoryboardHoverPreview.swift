import SwiftUI

// MARK: - StoryboardHoverPreview

/// YouTube-style scrub preview for the on-video progress bar: the storyboard
/// cell nearest the hovered position plus a timestamp, floating above the bar.
/// The sheet image comes from the same (validated) storyboard spec the ambient
/// backdrop uses, but at the spec's highest-resolution level; sheets are
/// fetched one at a time on demand and cached by `ImageCache`.
struct StoryboardHoverPreview: View {
    let spec: String
    /// 0…1 position under the pointer.
    let fraction: Double
    /// Video duration in seconds, for the timestamp label.
    let duration: Double

    static let previewWidth: CGFloat = 168
    /// Image + spacing + timestamp capsule. The player bar uses this to lift
    /// the bubble fully above the track and the "most replayed" band.
    static let totalHeight: CGFloat = 120

    @State private var cellImage: CGImage?

    private var previewSeconds: Int {
        Int(min(max(0, self.fraction), 1) * max(0, self.duration))
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.black.opacity(0.55))
                if let cellImage = self.cellImage {
                    Image(decorative: cellImage, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            .frame(width: Self.previewWidth, height: Self.previewWidth * 9 / 16)
            .clipShape(.rect(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)

            Text(Self.formatTime(self.previewSeconds))
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.black.opacity(0.55), in: .capsule)
        }
        // Storyboard frames are seconds apart, so re-resolving the cell at
        // 1-second hover granularity is enough; the crop itself is cheap and
        // the sheet fetch is cached.
        .task(id: self.previewSeconds) {
            if let image = await Self.loadCell(spec: self.spec, fraction: self.fraction) {
                self.cellImage = image
            }
        }
        .accessibilityHidden(true)
    }

    /// Fetches (via the shared cache) the sheet containing `fraction` at the
    /// spec's highest-resolution level and crops out its cell. `nonisolated`
    /// so decode/crop stays off the main actor; only the Sendable `CGImage`
    /// crosses back.
    // swiftformat:disable modifierOrder
    nonisolated private static func loadCell(spec: String, fraction: Double) async -> CGImage? {
        // ponytail: maxSheets 50 covers ~4h at typical high-level cell
        // intervals; beyond that the preview pins to the last covered frame.
        guard let sheet = StoryboardSheet(spec: spec, level: .max, maxSheets: 50) else {
            return nil
        }
        let location = sheet.frameLocation(forFraction: fraction)
        guard sheet.sheetURLs.indices.contains(location.sheet) else { return nil }
        guard let nsImage = await ImageCache.shared.image(for: sheet.sheetURLs[location.sheet]),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            return nil
        }
        let rects = sheet.cellRects(
            forSheetAt: location.sheet,
            pixelWidth: cgImage.width,
            height: cgImage.height
        )
        guard rects.indices.contains(location.cell) else { return nil }
        return cgImage.cropping(to: rects[location.cell])
    }

    // swiftformat:enable modifierOrder

    private static func formatTime(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
