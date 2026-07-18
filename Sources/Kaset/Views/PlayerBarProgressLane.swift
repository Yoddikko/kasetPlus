import SwiftUI

// MARK: - PlayerBarProgressLane

struct PlayerBarProgressLane: View {
    let fraction: Double
    let accent: Color
    let elapsedText: String
    let remainingText: String
    let markers: [PlayerBarProgressMarker]
    let isLive: Bool
    let canSeek: Bool
    let isLoading: Bool
    let onScrub: (Double) -> Void
    let onCommit: () -> Void
    let onMarkerPreviewChange: (PlayerBarProgressMarker?) -> Void

    /// Optional colored segment markers drawn directly on the track.
    var segmentMarkers: [PlayerBarSegmentMarker] = []

    /// Optional "most replayed" heatmap samples, drawn as a curve above the
    /// track and revealed only while hovering/scrubbing the bar.
    var heatmap: [YouTubeHeatmapMarker] = []

    /// Reports the 0…1 track fraction under the pointer while hovering or
    /// scrubbing, and `nil` when the pointer leaves the bar. Drives the
    /// storyboard hover preview on the on-video overlay bar.
    var onHoverFractionChange: ((Double?) -> Void)?

    /// Height of the heatmap band. Its baseline sits on the track (YouTube
    /// style) and the filled area rises upward from the bar — that rising shape
    /// is what reads as "above the bar". The centre and both ends are cleared by
    /// the legibility mask, since the transport buttons sit directly above the
    /// track and the time text sits at the ends.
    private static let heatmapHeight: CGFloat = 20
    private static let heatmapGap: CGFloat = 6

    /// Horizontal alpha mask that fades the "most replayed" curve to transparent
    /// at the far ends (behind the elapsed/remaining time text) and in a central
    /// dip (behind the centered transport buttons), leaving it visible only in
    /// the two side regions between.
    private static var heatmapLegibilityMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.0),
                .init(color: .white, location: 0.06),
                .init(color: .white, location: 0.39),
                .init(color: .clear, location: 0.43),
                .init(color: .clear, location: 0.57),
                .init(color: .white, location: 0.61),
                .init(color: .white, location: 0.94),
                .init(color: .clear, location: 1.0),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var isDragging = false
    @State private var isHovering = false
    @State private var dragFraction: Double?
    @State private var previewChapterMarker: PlayerBarProgressMarker?

    private var clampedFraction: CGFloat {
        CGFloat(min(max(0, self.fraction), 1))
    }

    init(
        fraction: Double,
        accent: Color,
        elapsedText: String,
        remainingText: String,
        markers: [PlayerBarProgressMarker] = [],
        isLive: Bool,
        canSeek: Bool,
        isLoading: Bool,
        onScrub: @escaping (Double) -> Void,
        onCommit: @escaping () -> Void,
        onMarkerPreviewChange: @escaping (PlayerBarProgressMarker?) -> Void = { _ in },
        segmentMarkers: [PlayerBarSegmentMarker] = [],
        heatmap: [YouTubeHeatmapMarker] = [],
        onHoverFractionChange: ((Double?) -> Void)? = nil
    ) {
        self.fraction = fraction
        self.accent = accent
        self.elapsedText = elapsedText
        self.remainingText = remainingText
        self.markers = markers
        self.isLive = isLive
        self.canSeek = canSeek
        self.isLoading = isLoading
        self.onScrub = onScrub
        self.onCommit = onCommit
        self.onMarkerPreviewChange = onMarkerPreviewChange
        self.segmentMarkers = segmentMarkers
        self.heatmap = heatmap
        self.onHoverFractionChange = onHoverFractionChange
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(self.isLive ? String(localized: "LIVE") : self.elapsedText)
                    .foregroundStyle(self.isLive ? .red : .secondary)

                Spacer(minLength: 8)

                Text(self.isLive ? "" : self.remainingText)
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            .monospacedDigit()
            .lineLimit(1)
            .frame(height: 12)

            self.progressBar
        }
        .frame(height: 30)
        .accessibilityElement()
        .accessibilityLabel(String(localized: "Playback position"))
        .accessibilityValue(self.isLive ? String(localized: "Live stream") : "\(self.elapsedText), \(self.remainingText)")
        .accessibilityAdjustableAction { direction in
            guard self.canSeek else { return }
            switch direction {
            case .increment:
                self.nudge(by: 0.02)
            case .decrement:
                self.nudge(by: -0.02)
            @unknown default:
                break
            }
        }
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fillWidth = width * self.clampedFraction
            let thumbDiameter = PlayerBarSliderVisuals.thumbDiameter(
                isHovering: self.isHovering,
                isDragging: self.isDragging
            )
            let fillColor = self.isLoading ? self.loadingFillColor : self.accent
            let thumbColor = self.isLoading ? self.loadingThumbColor : self.accent
            let previewMarker = self.previewChapterMarker

            ZStack(alignment: .topLeading) {
                // "Most replayed" curve floats in a band above the track — a gap
                // "Most replayed" curve floats in a band above the track — a gap
                // separates it from the bar. Only the on-video overlay passes
                // heatmap data, and that bar only appears while the controls are
                // up, so no hover gate is needed.
                if !self.heatmap.isEmpty, !self.isLive, !self.isLoading {
                    PlayerBarHeatmapCurve(samples: self.heatmap)
                        .frame(width: width, height: Self.heatmapHeight)
                        // Mask BEFORE offset: `.offset` is a render-time shift
                        // that doesn't move layout bounds, so masking after it
                        // leaves the mask on the un-shifted frame and clips the
                        // curve to nothing.
                        .mask(Self.heatmapLegibilityMask)
                        .offset(y: -(Self.heatmapHeight + Self.heatmapGap))
                        .allowsHitTesting(false)
                }

                Capsule()
                    .fill(self.trackColor)
                    .frame(height: PlayerBarSliderVisuals.trackThickness)

                UnevenRoundedRectangle(
                    topLeadingRadius: 999,
                    bottomLeadingRadius: 999
                )
                .fill(fillColor)
                .frame(width: fillWidth, height: PlayerBarSliderVisuals.trackThickness)
                .opacity(self.isLive ? 0 : 1)

                // SponsorBlock segments sit above the progress fill so their
                // category colors remain visible after a segment was skipped.
                ForEach(Array(self.segmentMarkers.enumerated()), id: \.offset) { _, marker in
                    let segStart = CGFloat(marker.fractionStart) * width
                    let segEnd = CGFloat(marker.fractionEnd) * width
                    let segWidth = max(segEnd - segStart, 3)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(marker.color)
                        .frame(width: segWidth, height: PlayerBarSliderVisuals.trackThickness)
                        .offset(x: segStart)
                }

                if self.isLoading {
                    PlayerBarSliderLoadingShimmer(
                        colorScheme: self.colorScheme,
                        reduceMotion: self.reduceMotion
                    )
                    .frame(height: PlayerBarSliderVisuals.trackThickness)
                    .transition(.opacity)
                }

                ForEach(self.markers) { marker in
                    let isHighlighted = marker.id == previewMarker?.id
                    self.markerView(marker, isHighlighted: isHighlighted)
                        .offset(
                            x: self.markerX(marker, trackWidth: width, isHighlighted: isHighlighted),
                            y: -3
                        )
                        .opacity(self.isLive || self.isLoading ? 0 : 1)
                        .accessibilityHidden(true)
                }

                Circle()
                    .fill(thumbColor)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .offset(
                        x: min(max(0, fillWidth - thumbDiameter / 2), max(0, width - thumbDiameter)),
                        y: PlayerBarSliderVisuals.trackThickness / 2 - thumbDiameter / 2
                    )
                    .opacity(self.canSeek ? 1 : 0)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .animation(PlayerBarSliderVisuals.trackAnimation, value: self.isHovering)
            .animation(PlayerBarSliderVisuals.thumbAnimation, value: self.isDragging)
            .animation(PlayerBarSliderVisuals.thumbAnimation, value: self.isHovering)
            .animation(.easeInOut(duration: 0.18), value: self.isLoading)
            .padding(PlayerBarSliderVisuals.hitOutset)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard self.canSeek, width > 0 else { return }
                        self.isDragging = true
                        let x = value.location.x - PlayerBarSliderVisuals.hitOutset
                        let fraction = Double(min(max(0, x / width), 1))
                        self.dragFraction = fraction
                        self.updatePreviewMarker(self.nearestMarker(to: fraction, width: width))
                        self.onHoverFractionChange?(fraction)
                        self.onScrub(fraction)
                    }
                    .onEnded { value in
                        defer {
                            self.dragFraction = nil
                            self.updatePreviewMarker(nil)
                            self.onHoverFractionChange?(nil)
                            self.isDragging = false
                        }
                        guard self.canSeek, width > 0 else { return }
                        let x = value.location.x - PlayerBarSliderVisuals.hitOutset
                        let fraction = Double(min(max(0, x / width), 1))
                        let targetFraction = self.snappedFraction(fraction, width: width)
                        self.onScrub(targetFraction)
                        self.onCommit()
                    }
            )
            .onContinuousHover { phase in
                guard width > 0 else { return }
                switch phase {
                case let .active(location):
                    let x = location.x - PlayerBarSliderVisuals.hitOutset
                    let fraction = Double(min(max(0, x / width), 1))
                    if self.dragFraction == nil {
                        self.updatePreviewMarker(self.nearestMarker(to: fraction, width: width))
                        self.onHoverFractionChange?(fraction)
                    }
                case .ended:
                    if self.dragFraction == nil {
                        self.updatePreviewMarker(nil)
                        self.onHoverFractionChange?(nil)
                    }
                }
            }
            .padding(-PlayerBarSliderVisuals.hitOutset)
            .onHover { hovering in
                self.isHovering = hovering
                if !hovering {
                    if self.dragFraction == nil {
                        self.updatePreviewMarker(nil)
                        self.onHoverFractionChange?(nil)
                    }
                }
            }
        }
        .frame(height: 12)
    }

    private func updatePreviewMarker(_ marker: PlayerBarProgressMarker?) {
        guard self.previewChapterMarker != marker else { return }
        self.previewChapterMarker = marker
        self.onMarkerPreviewChange(marker)
    }

    private func markerX(_ marker: PlayerBarProgressMarker, trackWidth: CGFloat, isHighlighted: Bool) -> CGFloat {
        // Marker and thumb offsets are inside the visual-track ZStack. Gesture
        // locations subtract `hitOutset` because the gesture is attached after
        // padding expands the hit target; visual offsets do not include it.
        let markerWidth = self.markerWidth(isHighlighted: isHighlighted)
        return min(
            max(0, trackWidth * CGFloat(marker.fraction) - markerWidth / 2),
            max(0, trackWidth - markerWidth)
        )
    }

    private func markerView(_: PlayerBarProgressMarker, isHighlighted: Bool) -> some View {
        Capsule()
            .fill(self.markerFallbackFill(isHighlighted: isHighlighted))
            .frame(
                width: self.markerWidth(isHighlighted: isHighlighted),
                height: self.markerHeight(isHighlighted: isHighlighted)
            )
            .compatGlass(
                interactive: isHighlighted,
                tint: self.markerGlassTint(isHighlighted: isHighlighted),
                in: .capsule
            )
            .overlay {
                Capsule()
                    .strokeBorder(self.markerRimColor(isHighlighted: isHighlighted), lineWidth: 0.6)
            }
            .shadow(
                color: self.markerShadowColor(isHighlighted: isHighlighted),
                radius: isHighlighted ? 5 : 1.5,
                y: isHighlighted ? 2 : 0.5
            )
            .animation(PlayerBarSliderVisuals.thumbAnimation, value: isHighlighted)
    }

    private func markerWidth(isHighlighted: Bool) -> CGFloat {
        isHighlighted ? 8 : 4
    }

    private func markerHeight(isHighlighted: Bool) -> CGFloat {
        PlayerBarSliderVisuals.trackThickness + (isHighlighted ? 10 : 7)
    }

    private func snappedFraction(_ fraction: Double, width: CGFloat) -> Double {
        self.nearestMarker(to: fraction, width: width)?.fraction ?? fraction
    }

    private func nearestMarker(to fraction: Double, width: CGFloat) -> PlayerBarProgressMarker? {
        guard !self.markers.isEmpty, width > 0 else { return nil }
        let threshold = max(0.006, min(0.025, 14 / Double(width)))
        return self.markers
            .map { marker in (marker: marker, distance: abs(marker.fraction - fraction)) }
            .filter { $0.distance <= threshold }
            .min { lhs, rhs in lhs.distance < rhs.distance }?
            .marker
    }

    private func nudge(by delta: Double) {
        self.onScrub(min(1, max(0, self.fraction + delta)))
        self.onCommit()
    }

    private var trackColor: Color {
        PlayerBarSliderVisuals.trackColor(
            colorScheme: self.colorScheme,
            isActive: !self.isLoading && (self.isHovering || self.isDragging)
        )
    }

    private var loadingFillColor: Color {
        PlayerBarSliderVisuals.loadingFillColor(colorScheme: self.colorScheme)
    }

    private var loadingThumbColor: Color {
        PlayerBarSliderVisuals.loadingThumbColor(colorScheme: self.colorScheme)
    }

    private func markerGlassTint(isHighlighted: Bool) -> Color {
        if isHighlighted {
            return self.accent.opacity(self.colorScheme == .dark ? 0.48 : 0.34)
        }
        return self.colorScheme == .dark ? .white.opacity(0.10) : .black.opacity(0.06)
    }

    private func markerFallbackFill(isHighlighted: Bool) -> Color {
        if isHighlighted {
            return self.accent.opacity(self.colorScheme == .dark ? 0.50 : 0.34)
        }
        return self.colorScheme == .dark ? .white.opacity(0.20) : .black.opacity(0.14)
    }

    private func markerRimColor(isHighlighted: Bool) -> Color {
        if isHighlighted {
            return self.colorScheme == .dark ? .white.opacity(0.42) : .white.opacity(0.72)
        }
        return self.colorScheme == .dark ? .white.opacity(0.26) : .white.opacity(0.58)
    }

    private func markerShadowColor(isHighlighted: Bool) -> Color {
        if isHighlighted {
            return self.accent.opacity(self.colorScheme == .dark ? 0.36 : 0.22)
        }
        return .black.opacity(self.colorScheme == .dark ? 0.18 : 0.08)
    }
}

// MARK: - PlayerBarHeatmapCurve

/// Draws YouTube's "most replayed" curve: a filled intensity graph with a crisp
/// top line, baseline at the bottom (intensity 0) rising to the top (intensity 1).
private struct PlayerBarHeatmapCurve: View {
    let samples: [YouTubeHeatmapMarker]

    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0, self.samples.count > 1 else { return }
            let points = self.samples.map { sample in
                CGPoint(
                    x: min(max(0, sample.fraction), 1) * size.width,
                    y: size.height * (1 - min(max(0, sample.intensity), 1))
                )
            }

            var line = Path()
            line.move(to: points[0])
            for point in points.dropFirst() {
                line.addLine(to: point)
            }
            // Extend the last sample horizontally to the right edge so the fill
            // spans the full track (samples end just short of fraction 1.0).
            if let last = points.last {
                line.addLine(to: CGPoint(x: size.width, y: last.y))
            }

            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()

            context.fill(
                fill,
                with: .linearGradient(
                    Gradient(colors: [.white.opacity(0.14), .white.opacity(0.03)]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )
            context.stroke(line, with: .color(.white.opacity(0.4)), lineWidth: 1.0)
        }
    }
}

// MARK: - PlayerBarSegmentMarker

struct PlayerBarSegmentMarker {
    let fractionStart: Double
    let fractionEnd: Double
    let color: Color
}

// MARK: - PlayerBarProgressMarker

struct PlayerBarProgressMarker: Identifiable, Hashable {
    let id: String
    let fraction: Double
    let title: String?
    let subtitle: String?

    init(id: String, fraction: Double, title: String? = nil, subtitle: String? = nil) {
        self.id = id
        self.fraction = min(max(0, fraction), 1)
        self.title = title
        self.subtitle = subtitle
    }
}
