import SwiftUI

// MARK: - YouTubeShortsView

/// The Shorts experience: a vertical pager that autoplays one short at a
/// time. Scrolling up advances to the next short, scrolling down returns
/// to the previous one (snap paging).
struct YouTubeShortsView: View {
    let viewModel: YouTubeShortsViewModel

    /// When set (e.g. opened from a channel's Shorts tab), the pager starts on
    /// this short instead of the feed's first one.
    var initialShortId: String?

    @Environment(AuthService.self) private var authService
    @Environment(YouTubePlayerService.self) private var youtubePlayer

    /// The short currently snapped into view (drives autoplay).
    @State private var currentShortId: String?

    /// Debounces playback so a fast scroll doesn't fire a full page load for
    /// every short it flies past (each load cancels the last → nothing loads,
    /// janky scroll). Only the short you settle on loads.
    @State private var playDebounce: Task<Void, Never>?

    var body: some View {
        Group {
            switch self.viewModel.loadingState {
            case .idle, .loading:
                LoadingView()
            case let .error(error):
                ErrorView(
                    title: error.title,
                    message: error.message,
                    isRetryable: error.isRetryable
                ) {
                    Task {
                        await self.viewModel.refresh()
                    }
                }
            case .loaded, .loadingMore:
                if self.viewModel.shorts.isEmpty {
                    ContentUnavailableView {
                        Label(String(localized: "No Shorts right now"), systemImage: "rectangle.portrait.on.rectangle.portrait.angled")
                    } description: {
                        Text("Shorts from your feed appear here.", comment: "Empty Shorts surface description")
                    }
                } else {
                    self.pager
                }
            }
        }
        .navigationTitle(Text("Shorts", comment: "YouTube Shorts title"))
        // Keyed on the view-model identity so a cold-launch account swap (which
        // rebuilds the model) re-fires the load instead of leaving the fresh,
        // idle model stuck. See YouTubeHomeView for the full rationale.
        .task(id: ObjectIdentifier(self.viewModel)) {
            // The view model is swapped on an account change; this @State is from
            // the previous account. Reset it so the autoplay guard below selects
            // the new model's first short instead of keeping a stale ID that is
            // not in the new pager.
            self.currentShortId = nil
            await self.viewModel.load()
            // Select the entry short (the requested one from a channel, else the
            // feed's first). Setting currentShortId fires onChange → schedulePlay,
            // which is the single path that starts playback.
            if self.currentShortId == nil {
                self.currentShortId = (self.viewModel.shorts.first { $0.videoId == self.initialShortId }
                    ?? self.viewModel.shorts.first)?.videoId
            }
        }
        .onDisappear {
            self.playDebounce?.cancel()
            self.stopIfPlayingShort()
        }
    }

    // MARK: - Pager

    private var pager: some View {
        GeometryReader { geo in
            // The ScrollView extends under the nav bar and player bar, so its
            // paging viewport is the full height (visible area + both safe-area
            // insets). Each page must equal that viewport or paging drifts and
            // shorts slide under the bars. The short itself is sized to the
            // *visible* area and centred within the page, so it lands in the
            // clear region between the bars.
            let pageHeight = geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(self.viewModel.shorts) { short in
                        ShortPage(
                            short: short,
                            isActive: self.isPresenting(short)
                        )
                        .frame(height: geo.size.height)
                        .frame(height: pageHeight)
                        .id(short.videoId)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: self.$currentShortId)
            .scrollIndicators(.hidden)
            .background(.black)
            .ignoresSafeArea(edges: .vertical)
            .onChange(of: self.currentShortId) { _, shortId in
                self.schedulePlay(shortId)
            }
            .accessibilityIdentifier(AccessibilityID.YouTubeContent.shortsPager)
        }
    }

    /// Whether the live surface belongs to this short.
    private func isPresenting(_ short: YouTubeVideo) -> Bool {
        self.youtubePlayer.currentVideo?.videoId == short.videoId
            && self.youtubePlayer.surfaceLocation == .inline
    }

    /// Loads the short after the scroll settles on it (~350ms), cancelling any
    /// pending load for a short we only flew past. Prevents load thrashing.
    private func schedulePlay(_ shortId: String?) {
        self.playDebounce?.cancel()
        guard let shortId else { return }
        self.playDebounce = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self.play(shortId: shortId)
        }
    }

    private func play(shortId: String) {
        guard let short = self.viewModel.shorts.first(where: { $0.videoId == shortId }) else {
            return
        }
        guard self.youtubePlayer.currentVideo?.videoId != short.videoId else { return }
        self.youtubePlayer.play(video: short, usesCookieFreeDataStore: self.authService.shouldUseCookieFreePlaybackDataStore)
        self.youtubePlayer.activeInlineVideoId = short.videoId
    }

    /// Leaving the Shorts surface ends shorts playback (a vertical short in
    /// the 16:9 floating window would be all pillarbox).
    private func stopIfPlayingShort() {
        guard let current = self.youtubePlayer.currentVideo,
              current.isShort,
              self.viewModel.shorts.contains(where: { $0.videoId == current.videoId }),
              self.youtubePlayer.surfaceLocation == .inline
        else {
            return
        }
        self.youtubePlayer.stop()
    }
}

// MARK: - ShortsScrollForwarder

/// Transparent overlay that hands trackpad scrolls to the enclosing
/// pager — the WKWebView under it would otherwise swallow them.
private struct ShortsScrollForwarder: NSViewRepresentable {
    final class ForwardingView: NSView {
        override func scrollWheel(with event: NSEvent) {
            if let scrollView = self.enclosingScrollView {
                scrollView.scrollWheel(with: event)
            } else {
                self.nextResponder?.scrollWheel(with: event)
            }
        }
    }

    func makeNSView(context _: Context) -> ForwardingView {
        ForwardingView()
    }

    func updateNSView(_: ForwardingView, context _: Context) {}
}

// MARK: - ShortPage

/// One full-height page of the Shorts pager: the live 9:16 surface when
/// active, otherwise the thumbnail; title/channel overlaid at the bottom.
private struct ShortPage: View {
    let short: YouTubeVideo
    let isActive: Bool

    @Environment(YouTubePlayerService.self) private var youtubePlayer

    /// The short's (instant) thumbnail covers the video surface while it's still
    /// loading, so you see the short immediately instead of a ~2-3s black wait;
    /// it fades out the moment playback actually starts. Shown always for
    /// inactive pages.
    private var coverVisible: Bool {
        guard self.isActive else { return true }
        return self.youtubePlayer.currentVideo?.videoId == self.short.videoId
            && self.youtubePlayer.isPlaybackLoading
    }

    var body: some View {
        ZStack {
            if self.isActive {
                YouTubeWatchSurfaceView()
            }
            self.thumbnail
                .opacity(self.coverVisible ? 1 : 0)
                .allowsHitTesting(false)
        }
        .aspectRatio(9 / 16, contentMode: .fit)
        .animation(.easeOut(duration: 0.3), value: self.coverVisible)
        .overlay {
            // The video WebView consumes trackpad scrolls; forward them so
            // the pager keeps paging while the cursor is over the short.
            ShortsScrollForwarder()
        }
        .overlay(alignment: .bottom) {
            self.infoOverlay
        }
        .clipShape(.rect(cornerRadius: 12))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(self.short.title)
    }

    private var thumbnail: some View {
        CachedAsyncImage(
            url: self.short.thumbnailURL,
            targetSize: CGSize(width: 540, height: 960)
        ) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            Rectangle()
                .fill(.black)
                .overlay {
                    ProgressView()
                        .controlSize(.small)
                }
        }
    }

    /// Title / channel overlay at the bottom of the short, Shorts-style.
    private var infoOverlay: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(self.short.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)

            let detail = [self.short.channelName, self.short.viewCountText]
                .compactMap(\.self)
                .joined(separator: " · ")
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            LinearGradient(
                colors: [.clear, .black.opacity(0.6)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .allowsHitTesting(false)
    }
}

// MARK: - AccessibilityID Additions

extension AccessibilityID.YouTubeContent {
    static let shortsPager = "youtubeContent.shortsPager"
}
