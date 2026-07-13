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

    /// Local mirror of the player service's download-sheet request, so the
    /// player bar's download button works from the Shorts surface too.
    @State private var showsDownloadSheet = false

    /// Whether the comments panel is shown to the right of the short.
    @State private var showsComments = false

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
                    self.pagerWithComments
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
        // The player bar's download button just flips this flag; the watch view
        // presents the sheet, but Shorts aren't shown there — present it here too.
        .onChange(of: self.youtubePlayer.showsDownloadSheet) { _, newValue in
            if newValue {
                self.showsDownloadSheet = true
                self.youtubePlayer.showsDownloadSheet = false
            }
        }
        .sheet(isPresented: self.$showsDownloadSheet) {
            if let video = self.youtubePlayer.currentVideo {
                YouTubeDownloadSheet(videoId: video.videoId, videoTitle: video.title)
            }
        }
    }

    // MARK: - Pager

    /// The pager, with the comments panel slid in on the right when toggled.
    /// The panel is an **overlay** (not an HStack) so the pager — and the video
    /// surface it hosts — keeps its exact geometry; resizing it broke playback.
    private var pagerWithComments: some View {
        self.pager
            .overlay(alignment: .trailing) {
                if self.showsComments, let videoId = self.youtubePlayer.currentVideo?.videoId {
                    ShortsCommentsPanel(videoId: videoId, client: self.viewModel.client) {
                        withAnimation(.easeInOut(duration: 0.25)) { self.showsComments = false }
                    }
                    .frame(width: 360)
                    .frame(maxHeight: .infinity)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
    }

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
            .overlay(alignment: .bottomTrailing) {
                self.shortActions
            }
        }
    }

    // MARK: - Short Actions (like / dislike / comments)

    /// Like / dislike / comments rail for the current short, styled like the
    /// watch page's pills (not an oversized TikTok overlay). Reuses the player
    /// service's rating + Return-YouTube-Dislike counts (populated on play).
    /// Gated on `currentShortId` (stable while scrolling) so it doesn't flicker
    /// as `currentVideo` briefly changes between shorts.
    @ViewBuilder
    private var shortActions: some View {
        if self.currentShortId != nil {
            VStack(spacing: 10) {
                self.ratingPill(
                    icon: self.youtubePlayer.currentRating == .like ? "hand.thumbsup.fill" : "hand.thumbsup",
                    count: self.youtubePlayer.rydLikes,
                    isActive: self.youtubePlayer.currentRating == .like
                ) {
                    Task { await self.youtubePlayer.toggleLike() }
                }
                self.ratingPill(
                    icon: self.youtubePlayer.currentRating == .dislike ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                    count: self.youtubePlayer.rydDislikes,
                    isActive: self.youtubePlayer.currentRating == .dislike
                ) {
                    Task { await self.youtubePlayer.toggleDislike() }
                }
                self.ratingPill(
                    icon: "text.bubble",
                    count: nil,
                    isActive: self.showsComments
                ) {
                    withAnimation(.easeInOut(duration: 0.25)) { self.showsComments.toggle() }
                }
            }
            .padding(.trailing, 18)
            .padding(.bottom, 84)
        }
    }

    /// A compact capsule button matching the watch page's like/dislike style,
    /// with a translucent backing so it stays legible over the video.
    private func ratingPill(
        icon: String,
        count: Int?,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                if let count {
                    Text(YouTubePlayerService.formatCount(count))
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .foregroundStyle(isActive ? Color.accentColor : .white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(.black.opacity(0.4)))
        }
        .buttonStyle(.plain)
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

// MARK: - ShortsCommentsPanel

/// A side panel of comments for the current short. Fetches the video's comment
/// continuation (via watch-next) then the first page, reloading when the short
/// changes. Read-only for now — matches the Shorts overlay, not the full watch
/// comments UI.
private struct ShortsCommentsPanel: View {
    let videoId: String
    let client: any YouTubeClientProtocol
    let onClose: () -> Void

    @State private var comments: [YouTubeComment] = []
    @State private var isLoading = false
    @State private var loadedVideoId: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Comments", comment: "Shorts comments panel title")
                    .font(.headline)
                Spacer()
                Button(action: self.onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Close comments"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            Group {
                if self.isLoading, self.comments.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if self.comments.isEmpty {
                    ContentUnavailableView(
                        "No comments",
                        systemImage: "bubble",
                        description: Text("This short has no comments yet.", comment: "Empty shorts comments")
                    )
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(self.comments) { comment in
                                ShortsCommentRow(comment: comment, client: self.client)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.regularMaterial)
        .task(id: self.videoId) {
            await self.load()
        }
    }

    private func load() async {
        guard self.loadedVideoId != self.videoId else { return }
        self.loadedVideoId = self.videoId
        self.comments = []
        self.isLoading = true
        defer { self.isLoading = false }
        do {
            let watchNext = try await self.client.getWatchNext(videoId: self.videoId)
            guard let token = watchNext.commentsContinuation else { return }
            guard !Task.isCancelled else { return }
            let page = try await self.client.getComments(continuation: token)
            guard self.loadedVideoId == self.videoId else { return }
            self.comments = page.comments
        } catch {
            // Leave the panel empty on failure; it's non-critical.
        }
    }
}

// MARK: - ShortsCommentRow

private struct ShortsCommentRow: View {
    let comment: YouTubeComment
    let client: any YouTubeClientProtocol

    @State private var isLiked = false
    @State private var isDisliked = false
    @State private var showsReplies = false
    @State private var replies: [YouTubeComment] = []
    @State private var loadingReplies = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CachedAsyncImage(
                url: self.comment.authorAvatarURL,
                targetSize: CGSize(width: 32, height: 32)
            ) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Circle().fill(.quaternary)
            }
            .frame(width: 32, height: 32)
            .clipShape(.circle)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(self.comment.author)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    if let published = self.comment.publishedText {
                        Text(published)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(self.comment.text)
                    .font(.caption)
                    .textSelection(.enabled)

                HStack(spacing: 14) {
                    Button(action: self.toggleLike) {
                        HStack(spacing: 4) {
                            Image(systemName: self.isLiked ? "hand.thumbsup.fill" : "hand.thumbsup")
                            if let likes = self.comment.likeCountText, !likes.isEmpty {
                                Text(likes)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(self.isLiked ? Color.accentColor : .secondary)

                    Button(action: self.toggleDislike) {
                        Image(systemName: self.isDisliked ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(self.isDisliked ? Color.accentColor : .secondary)
                }
                .font(.caption2)
                .padding(.top, 1)

                if self.comment.repliesContinuation != nil {
                    Button(action: self.toggleReplies) {
                        Label(
                            self.showsReplies ? String(localized: "Hide replies") : String(localized: "View replies"),
                            systemImage: self.showsReplies ? "chevron.up" : "chevron.down"
                        )
                        .font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 2)
                }

                if self.showsReplies {
                    if self.loadingReplies, self.replies.isEmpty {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.top, 4)
                    } else {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(self.replies) { reply in
                                ShortsCommentRow(comment: reply, client: self.client)
                            }
                        }
                        .padding(.top, 6)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func toggleLike() {
        let wasLiked = self.isLiked
        self.isLiked = !wasLiked
        if self.isLiked { self.isDisliked = false }
        guard let token = wasLiked ? self.comment.unlikeAction : self.comment.likeAction else { return }
        Task { try? await self.client.performCommentAction(token) }
    }

    private func toggleDislike() {
        let wasDisliked = self.isDisliked
        self.isDisliked = !wasDisliked
        if self.isDisliked { self.isLiked = false }
        guard let token = wasDisliked ? self.comment.undislikeAction : self.comment.dislikeAction else { return }
        Task { try? await self.client.performCommentAction(token) }
    }

    private func toggleReplies() {
        self.showsReplies.toggle()
        guard self.showsReplies, self.replies.isEmpty, !self.loadingReplies,
              let token = self.comment.repliesContinuation
        else { return }
        self.loadingReplies = true
        Task {
            defer { self.loadingReplies = false }
            if let page = try? await self.client.getComments(continuation: token) {
                self.replies = page.comments
            }
        }
    }
}

// MARK: - AccessibilityID Additions

extension AccessibilityID.YouTubeContent {
    static let shortsPager = "youtubeContent.shortsPager"
}
