import AppKit
import SwiftUI

// MARK: - YouTubeWatchView

/// Watch page for a YouTube video: the extracted video surface with native
/// controls, metadata, and the related list.
///
/// The surface is the singleton `YouTubeWatchWebView`, docked here while
/// this view owns it. Navigating away while playing hands the surface off
/// to the floating window (`YouTubeVideoWindowController`).
struct YouTubeWatchView: View {
    @MainActor fileprivate static var brandAccent: Color { SettingsManager.shared.accentColor }

    let video: YouTubeVideo

    @Environment(AuthService.self) private var authService
    @Environment(AccountService.self) private var accountService
    @Environment(YouTubePlayerService.self) private var youtubePlayer
    @Environment(\.openURL) private var openURL
    @State private var viewModel: YouTubeWatchViewModel

    init(video: YouTubeVideo, client: any YouTubeClientProtocol) {
        self.video = video
        self._viewModel = State(
            initialValue: YouTubeWatchViewModel(video: video, client: client)
        )
    }

    @State private var commentDraft = ""
    @State private var settings = SettingsManager.shared
    @State private var lyricsSearchQuery = ""
    @State private var showsDownloadSheet = false
    @State private var showsSavePopover = false

    /// Measured height of the left content column, used to cap the related rail
    /// so filtering the comments short can't leave a giant empty gap beside it.
    @State private var leftColumnHeight: CGFloat = 0

    /// Current width of the watch page content, used to decide whether the live
    /// chat can sit beside the video (side-by-side) or must stack below it.
    @State private var pageWidth: CGFloat = 0

    /// Measured height of the video surface, so the side live-chat column can
    /// match the video's height (like the official YouTube app).
    @State private var videoSurfaceHeight: CGFloat = 0

    /// Whether the on-video controls overlay is currently visible (shown while
    /// the cursor is over the video, when "controls on video" is enabled).
    @State private var overlayControlsVisible = false

    /// Idle countdown that hides the on-video overlay after the pointer stops
    /// moving for a few seconds (restarted on every movement).
    @State private var overlayHideTask: Task<Void, Never>?
    @State private var commentSearchQuery = ""
    @State private var liveChatDraft = ""

    /// Whether the "Collaborators" picker (for multi-channel uploads) is showing.
    @State private var showsCollaborators = false

    // AI video summary (on-device, macOS 26+). Stored as plain values so the
    // view doesn't reference the macOS-26-only VideoSummary type outside a guard.
    @State private var showsSummary = false
    @State private var showsDescription = false
    @State private var summaryTldr: String?
    @State private var summaryPoints: [String] = []
    @State private var summaryAudience: String?
    @State private var summaryLoading = false
    @State private var summaryError: String?

    private var resolvedTitle: String {
        if self.youtubePlayer.showsDearrowOriginal,
           let orig = self.youtubePlayer.dearrowOriginalTitle
        {
            return orig
        }
        return self.youtubePlayer.dearrowTitle
            ?? self.viewModel.data.videoTitle
            ?? self.video.title
    }

    private var hasDearrow: Bool {
        self.youtubePlayer.dearrowTitle != nil
    }

    private var askAccountScope: YouTubeAskAccountScopeObservation {
        YouTubeAskAccountScopeObservation(
            authenticationGeneration: self.authService.accountIdentityGeneration,
            hasPersonalAccount: self.authService.hasPersonalAccount,
            accountScopeID: self.accountService.currentAccountScopeID,
            isPrimaryAccount: self.accountService.currentAccount?.isPrimary,
            verifiedIdentitySequence: self.accountService.verifiedIdentitySequence
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                self.videoWithOptionalSideChat

                // Below the video: title/metadata + chapters/comments down the
                // left, the related rail down the right.
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 16) {
                        self.metadataSection

                        if let description = self.descriptionText {
                            self.descriptionSection(description)
                        }

                        if self.showsSummary, !self.isLiveStream {
                            Divider()
                            self.summarySection
                        }

                        if self.youtubePlayer.showsLyrics, !self.isLiveStream {
                            Divider()
                            self.lyricsSection
                        }

                        if !self.viewModel.data.chapters.isEmpty {
                            Divider()

                            WatchChaptersSection(
                                chapters: self.viewModel.data.chapters,
                                videoId: self.video.videoId,
                                onSeek: self.seekToChapter
                            )
                        }

                        // Distraction-free mode hides the comments and the
                        // related rail, leaving just the video and its metadata.
                        // Live streams show live chat instead of comments (like
                        // YouTube), so the comments section is hidden for them.
                        if !self.settings.distractionFreeEnabled, !self.viewModel.hasLiveChat {
                            Divider()

                            self.commentsSection
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { newHeight in
                        self.leftColumnHeight = newHeight
                    }

                    if !self.settings.distractionFreeEnabled {
                        // Capped to the left column's height and scrolls internally
                        // when taller, so a short (e.g. search-filtered) comment
                        // column can't leave a giant empty gap next to a tall rail.
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 20) {
                                // When the chat sits beside the video (wide
                                // window, live stream) it's shown up top; only
                                // fall back to stacking it here when it can't.
                                if self.viewModel.hasLiveChat, !self.showsSideChat {
                                    self.liveChatSection(height: 440)
                                }
                                self.relatedColumn
                            }
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(width: 360)
                        .frame(maxHeight: self.leftColumnHeight > 0 ? self.leftColumnHeight : nil)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { newWidth in
                self.pageWidth = newWidth
            }
        }
        .disabled(self.viewModel.ask.isExpanded)
        // PROTOTYPE: full-bleed ambient color behind the page. `.ignoresSafeArea`
        // (inside the host) lets it bleed under the bottom player-bar inset,
        // so the bar's Liquid Glass capsule refracts the live color. Hosted in
        // a child view so ITS body — not this whole page — is what re-renders
        // on the 1 Hz playback-progress updates the live style follows.
        .background {
            WatchAmbientBackground(video: self.video)
        }
        // The in-page metadata shows the title; keep the bar clean.
        .navigationTitle(String(localized: ""))
        // Let the ambient reach under the nav bar, like the other accent pages.
        .toolbarBackgroundVisibility(.hidden, for: .automatic)
        .toolbar {
            if self.viewModel.ask.isAvailable {
                ToolbarItem(placement: .primaryAction) {
                    YouTubeAskToolbarButton(viewModel: self.viewModel.ask)
                }
            }
        }
        .overlay {
            YouTubeAskFloatingOverlay(
                viewModel: self.viewModel.ask,
                playerOffsetMilliseconds: self.askPlayerOffsetMilliseconds
            )
        }
        .youtubeAskAccessibilityAnnouncements(viewModel: self.viewModel.ask)
            .toolbar {
                self.ambientStylePicker
            }
            .onChange(of: self.youtubePlayer.showsDownloadSheet) { _, newValue in
                if newValue {
                    self.showsDownloadSheet = true
                    self.youtubePlayer.showsDownloadSheet = false
                }
            }
            .sheet(isPresented: self.$showsDownloadSheet) {
                YouTubeDownloadSheet(
                    videoId: self.video.videoId,
                    videoTitle: self.viewModel.data.videoTitle ?? self.video.title
                )
            }
            .task {
                self.startOrAdoptPlayback()
            }
            .task(id: self.askAccountScope) {
                let accountScope = self.askAccountScope
                await self.viewModel.load(accountScope: accountScope)
                // Feed the related list to the player so the bar's next/previous
                // buttons can skip between videos.
                if self.youtubePlayer.currentVideo?.videoId == self.video.videoId {
                    self.youtubePlayer.setUpNext(self.upNextQueue)
                    self.youtubePlayer.setChapters(self.viewModel.data.chapters)
                    self.youtubePlayer.setHeatmap(self.viewModel.data.heatmap)
                }
            }
            .onDisappear {
                self.viewModel.cancel()
                self.youtubePlayer.inlineSurfaceWillDisappear(videoId: self.video.videoId)
                self.overlayHideTask?.cancel()
                self.youtubePlayer.inlineVideoOnScreen = false
                self.viewModel.stopLiveChat()
            }
    }

    private var askPlayerOffsetMilliseconds: Int64 {
        guard self.youtubePlayer.currentVideo?.videoId == self.video.videoId else {
            return 0
        }
        return YouTubeAskPlayerOffset.milliseconds(for: self.youtubePlayer.progress)
    }

    /// Shows the on-video controls and (re)starts the idle countdown that hides
    /// them ~5s after the pointer last moved.
    private func revealOverlayControls() {
        if !self.overlayControlsVisible {
            withAnimation(.easeInOut(duration: 0.2)) { self.overlayControlsVisible = true }
        }
        self.overlayHideTask?.cancel()
        self.overlayHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, !self.youtubePlayer.isControlOverlayPinned else { return }
            withAnimation(.easeInOut(duration: 0.2)) { self.overlayControlsVisible = false }
        }
    }

    // MARK: - Ambient Style Picker

    /// Toolbar control to switch ambient styles live on the watch page.
    /// Binds to the same `SettingsManager` value as the Settings → YouTube
    /// tab, so there is a single source of truth.
    @ToolbarContentBuilder
    private var ambientStylePicker: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Menu {
                Picker("Ambient", selection: self.$settings.ambientBackdropStyle) {
                    ForEach(AmbientBackdropStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "paintpalette")
            }
            .help(String(localized: "Ambient backdrop style"))
        }
    }

    // MARK: - Video + Side Chat

    /// Fixed width of the live-chat column when shown beside the video.
    private static let sideChatWidth: CGFloat = 340

    /// The page must be at least this wide before the chat can sit beside the
    /// video; below it the chat stacks below (in the related column) instead.
    private static let sideChatMinPageWidth: CGFloat = 820

    /// Whether the live chat should render as a column beside the video (like
    /// the official YouTube app) rather than stacked below it. Only for live
    /// streams with an available chat, and only when the window is wide enough
    /// to leave the video a reasonable size next to the chat column.
    private var showsSideChat: Bool {
        self.viewModel.hasLiveChat
            && !self.settings.distractionFreeEnabled
            && self.pageWidth >= Self.sideChatMinPageWidth
    }

    /// The top of the watch page: the video surface, with the live chat beside
    /// it (side-by-side) for live streams on a wide-enough window, or on its own
    /// (chat falls back to the related column below) otherwise.
    @ViewBuilder
    private var videoWithOptionalSideChat: some View {
        if self.showsSideChat {
            HStack(alignment: .top, spacing: 16) {
                self.videoSurface
                    .contextMenu { self.videoContextMenu }
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { newHeight in
                        self.videoSurfaceHeight = newHeight
                    }

                self.liveChatSection(
                    height: self.videoSurfaceHeight > 0 ? self.videoSurfaceHeight : 440
                )
                .frame(width: Self.sideChatWidth)
            }
        } else {
            self.videoSurface
                .contextMenu { self.videoContextMenu }
        }
    }

    // MARK: - Video Surface

    /// Whether this view currently presents the live playback surface.
    private var presentsLiveSurface: Bool {
        self.youtubePlayer.currentVideo?.videoId == self.video.videoId
            && self.youtubePlayer.surfaceLocation == .inline
    }

    /// Whether this view's video is currently playing in the floating window.
    private var playsInFloatingWindow: Bool {
        self.youtubePlayer.currentVideo?.videoId == self.video.videoId
            && self.youtubePlayer.surfaceLocation == .floating
    }

    @ViewBuilder
    private var videoSurface: some View {
        if self.presentsLiveSurface {
            // Clean video surface. Controls live either in the docked bar or,
            // when "controls on video" is enabled, overlaid on the video here
            // (reusing the exact same YouTubePlayerBar in `.videoOverlay` mode).
            YouTubeWatchSurfaceView()
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(alignment: .bottom) {
                    if self.settings.controlsOnVideoEnabled, self.overlayControlsVisible {
                        YouTubePlayerBar(mode: .videoOverlay)
                            .transition(.opacity)
                    }
                }
                // Loading state: the WebView surface is black until the stream
                // is ready, so show a spinner over it instead of a blank frame.
                // For a members-only video the user can't play, no stream ever
                // arrives — show YouTube's real gate notice instead of spinning.
                .overlay {
                    if let gate = self.viewModel.membersGate {
                        self.membersGateCard(gate)
                            .transition(.opacity)
                    } else if self.youtubePlayer.isPlaybackLoading {
                        ZStack {
                            Rectangle().fill(.black)
                            ProgressView()
                                .controlSize(.large)
                                .tint(.white)
                        }
                        .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: self.youtubePlayer.isPlaybackLoading)
                .animation(.easeInOut(duration: 0.25), value: self.viewModel.membersGate == nil)
                // YouTube-style "up next" countdown card when a finished video is
                // about to autoplay the next one.
                .overlay {
                    YouTubeAutoplayCountdownOverlay()
                }
                .animation(.easeInOut(duration: 0.25), value: self.youtubePlayer.autoplayPendingVideo == nil)
                // "Ad" badge: a server-side (SSAI) ad can still slip past the
                // blocker; label it so it's clear this isn't the content.
                .overlay(alignment: .topLeading) {
                    if self.youtubePlayer.isShowingAd {
                        Text("Ad", comment: "Badge shown while a YouTube ad is playing")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.yellow, in: .rect(cornerRadius: 3))
                            .padding(10)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: self.youtubePlayer.isShowingAd)
                // Native "Skip Ad" button — DISABLED for now. Every skip path we
                // tried (synthetic Skip click, loadVideoById, playbackRate, seek)
                // either left the content stuck black or was reset by YouTube.
                // Ads are shown (muted) with the "Ad" badge until we land a skip
                // that reliably hands off to the content. `isAdSkippable` is
                // still plumbed so re-enabling is a one-line change.
                //
                // .overlay(alignment: .bottomTrailing) {
                //     if self.youtubePlayer.isShowingAd, self.youtubePlayer.isAdSkippable {
                //         Button {
                //             self.youtubePlayer.skipAd()
                //             HapticService.toggle()
                //         } label: {
                //             HStack(spacing: 6) {
                //                 Text("Skip Ad", comment: "Button to skip a YouTube ad")
                //                     .font(.system(size: 13, weight: .semibold))
                //                 Image(systemName: "forward.end.fill")
                //                     .font(.system(size: 11))
                //             }
                //             .foregroundStyle(.white)
                //             .padding(.horizontal, 14)
                //             .padding(.vertical, 8)
                //             .background(.black.opacity(0.55), in: .capsule)
                //             .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                //         }
                //         .buttonStyle(.plain)
                //         .padding(.trailing, 16)
                //         .padding(.bottom, 76)
                //         .transition(.opacity)
                //     }
                // }
                .overlay(alignment: .topTrailing) {
                    SponsorBlockSkipNoticeOverlay()
                        .padding(16)
                }
                .clipShape(.rect(cornerRadius: 12))
                .onContinuousHover { phase in
                    guard self.settings.controlsOnVideoEnabled else { return }
                    switch phase {
                    case .active:
                        // Any pointer movement reveals the controls and restarts
                        // the idle countdown.
                        self.revealOverlayControls()
                    case .ended:
                        guard !self.youtubePlayer.isControlOverlayPinned else { return }
                        self.overlayHideTask?.cancel()
                        withAnimation(.easeInOut(duration: 0.2)) {
                            self.overlayControlsVisible = false
                        }
                    }
                }
                // When the video scrolls out of the watch page, bring the docked
                // bar back so playback stays controllable.
                .onAppear { self.youtubePlayer.inlineVideoOnScreen = true }
                .onScrollVisibilityChange(threshold: 0.35) { visible in
                    self.youtubePlayer.inlineVideoOnScreen = visible
                }
                .accessibilityIdentifier(AccessibilityID.YouTubeContent.watchSurface)
        } else if self.playsInFloatingWindow {
            // Native PiP-style placeholder while the video plays in the
            // pop-out window.
            Rectangle()
                .fill(.black)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    VStack(spacing: 12) {
                        Image(systemName: "pip.exit")
                            .font(.system(size: 40))
                            .foregroundStyle(.white.opacity(0.7))
                        Text("This video is playing in the pop-out player.", comment: "Watch view placeholder while popped out")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.7))
                        Button {
                            self.youtubePlayer.dockInline()
                            HapticService.toggle()
                        } label: {
                            Text("Move Video Here", comment: "Button that docks the popped-out video back inline")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                        .accessibilityIdentifier(AccessibilityID.YouTubeContent.watchMoveHere)
                    }
                }
                .clipShape(.rect(cornerRadius: 12))
                .accessibilityIdentifier(AccessibilityID.YouTubeContent.watchSurface)
        } else {
            Button {
                self.startOrAdoptPlayback()
            } label: {
                CachedAsyncImage(
                    url: self.video.thumbnailURL,
                    targetSize: CGSize(width: 1280, height: 720)
                ) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(.black)
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(radius: 8)
                }
                .clipShape(.rect(cornerRadius: 12))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Play video"))
            .accessibilityIdentifier(AccessibilityID.YouTubeContent.watchSurface)
        }
    }

    /// Starts playback of this view's video, or adopts the surface if this
    /// video is already playing (e.g. docking back from the floating window).
    private func startOrAdoptPlayback(startAt: Double? = nil) {
        if self.youtubePlayer.currentVideo?.videoId == self.video.videoId {
            if self.youtubePlayer.surfaceLocation == .floating {
                self.youtubePlayer.dockInline()
            }
        } else {
            self.youtubePlayer.play(
                video: self.video,
                usesCookieFreeDataStore: self.authService.shouldUseCookieFreePlaybackDataStore,
                startAt: startAt
            )
        }
        self.youtubePlayer.setUpNext(self.upNextQueue)
        self.youtubePlayer.setChapters(self.viewModel.data.chapters)
        self.youtubePlayer.setHeatmap(self.viewModel.data.heatmap)
        self.youtubePlayer.activeInlineVideoId = self.video.videoId
    }

    // MARK: - Metadata

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(self.resolvedTitle)
                    .font(.title2.bold())
                    .lineLimit(3)

                if self.hasDearrow {
                    Button {
                        self.youtubePlayer.showsDearrowOriginal.toggle()
                    } label: {
                        Image(systemName: self.youtubePlayer.showsDearrowOriginal
                            ? "arrow.uturn.backward.circle.fill" : "arrow.triangle.swap")
                            .font(.system(size: 14))
                            .foregroundStyle(self.youtubePlayer.showsDearrowOriginal ? .orange : SponsorSegment.brandColor)
                    }
                    .buttonStyle(.plain)
                    .help(self.youtubePlayer.showsDearrowOriginal
                        ? String(localized: "Show DeArrow title")
                        : String(localized: "Show original title"))
                }
            }

            // Views · published (left) + like/dislike (right) — same row
            let meta = [
                self.viewModel.data.viewCountText ?? self.video.viewCountText,
                self.viewModel.data.publishedText ?? self.video.publishedText,
            ].compactMap(\.self)
            if !meta.isEmpty {
                Text(meta.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            // Channel on the left, engagement actions on the right (YouTube-style
            // two sides). The whole cluster drops the actions onto their own
            // wrapped line when the column is too narrow for one row.
            if !self.viewModel.collaborators.isEmpty {
                self.collaboratorsRow(self.viewModel.collaborators)
                FlowLayout(spacing: 8, lineSpacing: 8) { self.engagementButtons }
            } else if let channel = self.viewModel.data.channel {
                // Stable two-sided row: channel on the left, engagement actions
                // pushed to the right by the Spacer. Deterministic (no
                // ViewThatFits branch-flipping when the async like counts load).
                HStack(alignment: .center, spacing: 12) {
                    self.channelInfoLink(channel)
                    self.channelActionButtons
                    Spacer(minLength: 12)
                    HStack(spacing: 8) { self.engagementButtons }
                }
            }

            // KasetPlus tools (Summary, Lyrics). Hidden for live streams.
            if !self.isLiveStream {
                FlowLayout(spacing: 8, lineSpacing: 8) { self.toolsButtons }
            }

        }
    }

    // MARK: Channel & action button groups

    @ViewBuilder private var engagementButtons: some View {
        if self.hasPersonalAccount {
            self.likeDislikeButtons
            self.saveButton
        }
        self.shareButton
        self.downloadButton
    }

    @ViewBuilder private var channelActionButtons: some View {
        if self.hasPersonalAccount {
            self.subscribeButton
            self.membershipButton
            self.notificationBellButton
        }
    }

    private func channelInfoLink(_ channel: YouTubeChannel) -> some View {
        NavigationLink(value: YouTubeRoute.channel(channelId: channel.channelId)) {
            HStack(spacing: 10) {
                CachedAsyncImage(
                    url: channel.thumbnailURL,
                    targetSize: CGSize(width: 36, height: 36)
                ) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Circle().fill(.quaternary)
                }
                .frame(width: 36, height: 36)
                .clipShape(.circle)

                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    if let subscriberCountText = channel.subscriberCountText {
                        Text(subscriberCountText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// KasetPlus-only tools: on-device AI summary and lyrics toggles.
    @ViewBuilder private var toolsButtons: some View {
        if self.aiSummaryAvailable {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.showsSummary.toggle()
                }
                if self.showsSummary, self.summaryTldr == nil, !self.summaryLoading {
                    self.generateSummary()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13))
                    Text("Summary", comment: "Toggle AI video summary in YouTube watch view")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 13)
                .frame(height: 34)
                .compatGlass(interactive: true, tint: self.showsSummary ? Self.brandAccent : nil, in: Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(self.showsSummary ? Color.accentColor : .secondary)
        }

        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                self.youtubePlayer.showsLyrics.toggle()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: self.youtubePlayer.showsLyrics ? "music.quarternote.3" : "music.note.list")
                    .font(.system(size: 13))
                Text("Lyrics", comment: "Toggle lyrics section in YouTube watch view")
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 13)
            .frame(height: 34)
            .compatGlass(interactive: true, tint: self.youtubePlayer.showsLyrics ? Self.brandAccent : nil, in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(self.youtubePlayer.showsLyrics ? Color.accentColor : .secondary)
    }

    private var watchURL: URL? {
        URL(string: "https://www.youtube.com/watch?v=\(self.video.videoId)")
    }

    /// Native macOS share sheet for the video link.
    @ViewBuilder private var shareButton: some View {
        if let url = self.watchURL {
            ShareLink(item: url) {
                self.actionPillLabel("square.and.arrow.up", Text("Share", comment: "Share the video"))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    /// Direct Download pill — opens the app's download sheet (replaced the
    /// overflow "…" menu, which only held Download + Copy link).
    private var downloadButton: some View {
        self.actionPill("arrow.down.circle", Text("Download", comment: "Download the video")) {
            self.showsDownloadSheet = true
        }
    }

    /// "Save" — opens the add-to-playlist popover (Watch Later, the user's
    /// playlists, and creating a new one). Mirrors YouTube's web Save button.
    /// A pill action button whose glass capsule shows icon + label when there's
    /// room, and collapses to icon-only when there isn't — it never truncates
    /// the label.
    private func actionPill(_ systemImage: String, _ label: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            self.actionPillLabel(systemImage, label)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private func actionPillLabel(_ systemImage: String, _ label: Text) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 13))
                label
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 13)
            .frame(height: 34)

            Image(systemName: systemImage)
                .font(.system(size: 14))
                .frame(width: 36, height: 34)
        }
        .compatGlass(interactive: true, in: Capsule())
    }

    private var saveButton: some View {
        self.actionPill("bookmark", Text("Save", comment: "Save video to a playlist")) {
            self.showsSavePopover = true
        }
        .popover(isPresented: self.$showsSavePopover, arrowEdge: .bottom) {
            YouTubeSaveToPlaylistView(videoId: self.video.videoId, client: self.viewModel.client)
        }
    }

    /// Like / dislike as a single segmented pill (thumb-up + count · divider ·
    /// thumb-down + count), matching YouTube's joined control.
    private var likeDislikeButtons: some View {
        HStack(spacing: 0) {
            Button {
                Task { await self.youtubePlayer.toggleLike() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: self.youtubePlayer.currentRating == .like
                        ? "hand.thumbsup.fill" : "hand.thumbsup")
                        .font(.system(size: 13))
                    if let likes = self.youtubePlayer.rydLikes {
                        Text(YouTubePlayerService.formatCount(likes))
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .foregroundStyle(self.youtubePlayer.currentRating == .like ? Self.brandAccent : .secondary)
                .padding(.leading, 14)
                .padding(.trailing, 12)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider().frame(height: 16)

            Button {
                Task { await self.youtubePlayer.toggleDislike() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: self.youtubePlayer.currentRating == .dislike
                        ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                        .font(.system(size: 13))
                    if let dislikes = self.youtubePlayer.rydDislikes {
                        Text(YouTubePlayerService.formatCount(dislikes))
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .foregroundStyle(self.youtubePlayer.currentRating == .dislike ? Self.brandAccent : .secondary)
                .padding(.leading, 12)
                .padding(.trailing, 14)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(height: 34)
        .fixedSize()
        .compatGlass(interactive: true, in: Capsule())
    }

    // MARK: - Description

    /// The video's description text from the watch page, if any (non-empty).
    private var descriptionText: String? {
        guard let text = self.viewModel.data.descriptionText?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else {
            return nil
        }
        return text
    }

    /// Collapsible description box: a 3-line preview by default (like YouTube),
    /// with a "Show more"/"Show less" toggle when there's more to see.
    private func descriptionSection(_ text: String) -> some View {
        // ponytail: cheap "is it long enough to need a toggle" heuristic — a few
        // newlines or a paragraph's worth of text. Avoids measuring truncation.
        let isExpandable = text.count > 160 || text.filter { $0 == "\n" }.count >= 3

        return VStack(alignment: .leading, spacing: 8) {
            Text(Self.makeDescriptionAttributed(text))
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .tint(.accentColor)
                .textSelection(.enabled)
                .lineLimit(self.showsDescription ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Timestamps seek in-place; real links open in the browser.
                .environment(\.openURL, OpenURLAction { url in self.handleDescriptionLink(url) })

            if isExpandable {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { self.showsDescription.toggle() }
                } label: {
                    Text(self.showsDescription
                        ? String(localized: "Show less", comment: "Collapse the video description")
                        : String(localized: "Show more", comment: "Expand the video description"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.10)))
        // Tapping the whole card expands it (only while collapsed — once open,
        // taps pass through to text selection / links; collapse via "Show less").
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture {
            guard isExpandable, !self.showsDescription else { return }
            withAnimation(.easeInOut(duration: 0.2)) { self.showsDescription = true }
        }
    }

    /// Right-click menu on the video surface — the local subset of YouTube's own
    /// video context menu (copy links, embed, pop out). Loop / Stats-for-nerds
    /// need player-side plumbing the fork doesn't have yet, so they're omitted.
    @ViewBuilder private var videoContextMenu: some View {
        let videoURL = "https://www.youtube.com/watch?v=\(self.video.videoId)"

        Button {
            self.copyToPasteboard(videoURL)
        } label: {
            Label("Copy video URL", systemImage: "link")
        }

        Button {
            self.copyToPasteboard("\(videoURL)&t=\(Int(self.youtubePlayer.progress))s")
        } label: {
            Label("Copy URL at current time", systemImage: "clock")
        }

        Button {
            self.copyToPasteboard(
                "<iframe width=\"560\" height=\"315\" src=\"https://www.youtube.com/embed/\(self.video.videoId)\" frameborder=\"0\" allowfullscreen></iframe>"
            )
        } label: {
            Label("Copy embed code", systemImage: "chevron.left.forwardslash.chevron.right")
        }

        if self.youtubePlayer.surfaceLocation == .inline {
            Divider()
            Button {
                self.youtubePlayer.popOutToWindow()
            } label: {
                Label("Mini player", systemImage: "pip.enter")
            }
        }
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func handleDescriptionLink(_ url: URL) -> OpenURLAction.Result {
        if url.scheme == Self.seekLinkScheme, let seconds = Double(url.host() ?? "") {
            self.youtubePlayer.seek(to: seconds)
            return .handled
        }
        return .systemAction
    }

    private static let seekLinkScheme = "kaset-seek"

    /// Builds an attributed description: real URLs become browser links, and
    /// `mm:ss` / `h:mm:ss` timestamps become `kaset-seek://<seconds>` links that
    /// seek the player. Segment-by-segment so NSString (UTF-16) ranges from the
    /// detectors line up with the produced `AttributedString`.
    private static func makeDescriptionAttributed(_ text: String) -> AttributedString {
        struct Hit { let range: NSRange; let url: URL }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var hits: [Hit] = []

        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: text, range: full) {
                if let url = match.url {
                    hits.append(Hit(range: match.range, url: url))
                }
            }
        }

        if let regex = try? NSRegularExpression(pattern: #"(?<![\d:])(?:(\d{1,2}):)?(\d{1,2}):(\d{2})(?![\d:])"#) {
            for match in regex.matches(in: text, range: full) {
                // Don't turn a timestamp inside a matched URL into a seek link.
                guard !hits.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }) else { continue }
                func group(_ index: Int) -> Int {
                    let range = match.range(at: index)
                    return range.location == NSNotFound ? 0 : (Int(ns.substring(with: range)) ?? 0)
                }
                let seconds = group(1) * 3600 + group(2) * 60 + group(3)
                if let url = URL(string: "\(Self.seekLinkScheme)://\(seconds)") {
                    hits.append(Hit(range: match.range, url: url))
                }
            }
        }

        hits.sort { $0.range.location < $1.range.location }

        var result = AttributedString()
        var cursor = 0
        for hit in hits where hit.range.location >= cursor {
            if hit.range.location > cursor {
                result += AttributedString(ns.substring(with: NSRange(location: cursor, length: hit.range.location - cursor)))
            }
            var segment = AttributedString(ns.substring(with: hit.range))
            segment.link = hit.url
            result += segment
            cursor = hit.range.location + hit.range.length
        }
        if cursor < ns.length {
            result += AttributedString(ns.substring(from: cursor))
        }
        return result
    }

    // MARK: - AI Summary

    /// Whether on-device summarization is usable right now (macOS 26 + a ready model).
    private var aiSummaryAvailable: Bool {
        guard #available(macOS 26.0, *) else { return false }
        return FoundationModelsService.shared.isAvailable
    }

    /// A live broadcast has no transcript to summarize and no lyrics, so both
    /// toggles (and their panels) are hidden. Combines the fetched metadata flag
    /// with the player's live state so it still holds when the video was opened
    /// without live metadata (e.g. from a notification).
    private var isLiveStream: Bool {
        self.youtubePlayer.isLive || self.video.isLive
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("AI Summary", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                if self.summaryLoading {
                    ProgressView().scaleEffect(0.7).frame(width: 16, height: 16)
                }
            }

            if self.summaryLoading {
                Text("Reading the transcript and summarizing on-device…", comment: "AI summary loading")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if let error = self.summaryError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if let tldr = self.summaryTldr {
                Text(tldr)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                if !self.summaryPoints.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(self.summaryPoints.enumerated()), id: \.offset) { _, point in
                            HStack(alignment: .top, spacing: 8) {
                                Circle().fill(.secondary).frame(width: 5, height: 5).padding(.top, 6)
                                Text(point).font(.system(size: 13))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.top, 2)
                }

                if let audience = self.summaryAudience, !audience.isEmpty {
                    Text(audience)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }

            Text("Generated on-device from the video's captions. May be imperfect.", comment: "AI summary disclaimer")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.06)) }
    }

    private func generateSummary() {
        self.summaryError = nil
        self.summaryLoading = true
        let videoId = self.video.videoId
        let title = self.viewModel.data.videoTitle ?? self.video.title
        Task {
            defer { self.summaryLoading = false }
            guard let transcript = await YouTubeDownloadService.shared.fetchTranscript(videoId: videoId),
                  transcript.count > 40
            else {
                self.summaryError = String(localized: "No captions available to summarize this video.")
                return
            }
            guard #available(macOS 26.0, *) else {
                self.summaryError = String(localized: "AI summary needs macOS 26.")
                return
            }
            do {
                let summary = try await FoundationModelsService.shared.summarizeVideo(title: title, transcript: transcript)
                self.summaryTldr = summary.tldr
                self.summaryPoints = summary.keyPoints
                self.summaryAudience = summary.audience
            } catch {
                self.summaryError = String(localized: "Couldn't summarize this video.")
            }
        }
    }

    // MARK: - Lyrics Section

    @State private var lyricsResults: [LRCLibModel] = []
    @State private var lyricsLoading = false
    @State private var lyricsExpandedID: Int?

    private var lyricsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Lyrics", systemImage: "music.quarternote.3")
                    .font(.headline)
                Spacer()
                if self.lyricsLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                }
            }

            // Editable search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                TextField(
                    String(localized: "Search artist - title..."),
                    text: self.$lyricsSearchQuery
                )
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit {
                    self.lyricsResults = []
                    self.lyricsExpandedID = nil
                    self.performLyricsSearch()
                }
                if !self.lyricsSearchQuery.isEmpty {
                    Button {
                        self.lyricsSearchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    self.lyricsResults = []
                    self.lyricsExpandedID = nil
                    self.performLyricsSearch()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(8)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.08))
            }

            if self.lyricsResults.isEmpty, !self.lyricsLoading {
                Text("No lyrics found for this song.", comment: "Empty lyrics state")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(self.lyricsResults.prefix(3), id: \.id) { track in
                    self.lyricsTrackRow(track)
                }
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.secondary.opacity(0.06))
        }
        .onAppear {
            if self.lyricsSearchQuery.isEmpty {
                self.lyricsSearchQuery = self.viewModel.data.videoTitle ?? self.video.title
            }
            self.performLyricsSearch()
        }
        .onChange(of: self.video.videoId) { _, _ in
            self.lyricsResults = []
            self.lyricsExpandedID = nil
            self.lyricsSearchQuery = self.viewModel.data.videoTitle ?? self.video.title
            self.performLyricsSearch()
        }
    }

    private func lyricsTrackRow(_ track: LRCLibModel) -> some View {
        let isExpanded = self.lyricsExpandedID == track.id
        return VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.lyricsExpandedID = isExpanded ? nil : track.id
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isExpanded ? "text.justify" : "music.note")
                        .font(.callout)
                        .foregroundStyle(isExpanded ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.trackName ?? track.artistName ?? String(localized: "Unknown"))
                            .font(.system(size: 12, weight: .semibold))
                        if let artist = track.artistName {
                            Text(artist)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(10)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isExpanded ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded, let lyrics = track.syncedLyrics ?? track.plainLyrics {
                ScrollView {
                    Text(Self.stripTimestamps(lyrics))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 220)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.04))
                }
                .padding(.top, 6)
            }
        }
    }

    private func performLyricsSearch() {
        let trimmed = self.lyricsSearchQuery.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !self.lyricsLoading else { return }

        self.lyricsLoading = true
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        guard let url = components.url else { self.lyricsLoading = false; return }

        var request = URLRequest(url: url)
        request.setValue("KasetPlus/1.0", forHTTPHeaderField: "User-Agent")

        Task {
            defer { self.lyricsLoading = false }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200
                else { return }
                let decoded = try JSONDecoder().decode([LRCLibModel].self, from: data)
                self.lyricsResults = decoded.filter {
                    ($0.syncedLyrics != nil || $0.plainLyrics != nil) &&
                        ($0.instrumental == false || $0.instrumental == nil)
                }
            } catch {}
        }
    }

    private static func stripTimestamps(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\\[\\d{2}:\\d{2}\\.\\d{2}\\]",
            with: "",
            options: .regularExpression
        )
    }

    private var subscribeButton: some View {
        Button {
            Task {
                await self.viewModel.toggleSubscribed()
            }
        } label: {
            Text(
                self.viewModel.isSubscribed
                    ? String(localized: "Subscribed")
                    : String(localized: "Subscribe")
            )
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(self.viewModel.isSubscribed ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
            .padding(.horizontal, 16)
            // Same height as the avatar / name + subscriber-count block.
            .frame(height: 36)
            .compatGlass(
                interactive: true,
                tint: self.viewModel.isSubscribed ? nil : Self.brandAccent,
                in: Capsule()
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.subscribeButton)
    }

    /// The channel to open a membership (Join / Abbonati) page for: the watch
    /// page's parsed owner, falling back to the source card's channel.
    private var membershipChannelId: String? {
        self.viewModel.data.channel?.channelId ?? self.video.channelId
    }

    /// "Join" (Abbonati) button shown next to Subscribe when the channel offers a
    /// paid membership. Paid flows aren't handled in-app — it opens YouTube.
    @ViewBuilder
    private var membershipButton: some View {
        if self.viewModel.data.channelOffersMembership, let channelId = self.membershipChannelId {
            self.abbonatiButton(channelId: channelId)
        }
    }

    /// The Join / Abbonati capsule that opens the channel's YouTube membership
    /// page in the browser (no in-app payment flow). Reused by the members-only
    /// gate card so joining is one click from the blocked video.
    private func abbonatiButton(channelId: String) -> some View {
        Button {
            self.openMembership(channelId: channelId)
        } label: {
            Text("Join", comment: "Button to join a channel's paid membership (Abbonati)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 36)
                .compatGlass(interactive: true, tint: Self.brandAccent, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Opens the channel's YouTube membership page. Membership/payment is handled
    /// on YouTube, never in-app.
    private func openMembership(channelId: String) {
        guard let url = URL(string: "https://www.youtube.com/channel/\(channelId)/join") else { return }
        self.openURL(url)
    }

    /// Members-only gate: replaces the endless spinner for a members-only video
    /// the signed-in user can't play. Shows YouTube's own dynamic reason /
    /// subreason plus a Join (Abbonati) action.
    private func membersGateCard(_ gate: YouTubePlayability) -> some View {
        ZStack {
            Rectangle().fill(.black)
            VStack(spacing: 12) {
                Image(systemName: "star.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Color(red: 0.18, green: 0.55, blue: 0.34))

                if let reason = gate.reason {
                    Text(reason)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                }

                if let subreason = gate.subreason {
                    Text(subreason)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                }

                if let channelId = self.membershipChannelId {
                    self.abbonatiButton(channelId: channelId)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 40)
            .frame(maxWidth: 520)
        }
    }

    /// The subscription notification "bell": a menu to pick the notification
    /// level (labels + options come straight from YouTube) or unsubscribe. Shown
    /// only when subscribed and YouTube exposed the preference.
    @ViewBuilder
    private var notificationBellButton: some View {
        if self.viewModel.isSubscribed, let preference = self.viewModel.notificationPreference {
            Menu {
                Picker(String(localized: "Notifications"), selection: self.notificationSelection) {
                    ForEach(preference.options) { option in
                        Label(option.label, systemImage: option.level.symbolName).tag(option.id)
                    }
                }
                .pickerStyle(.inline)

                Divider()

                Button(role: .destructive) {
                    Task { await self.viewModel.toggleSubscribed() }
                } label: {
                    Label(preference.unsubscribeLabel, systemImage: "person.fill.xmark")
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: preference.currentLevel.symbolName)
                        .font(.system(size: 13))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .compatGlass(interactive: true, tint: nil, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help(String(localized: "Notification settings"))
        }
    }

    /// Binding driving the notification-level picker (applies the choice on change).
    private var notificationSelection: Binding<String> {
        Binding(
            get: { self.viewModel.notificationPreference?.current?.id ?? "" },
            set: { newID in
                guard let option = self.viewModel.notificationPreference?.options
                    .first(where: { $0.id == newID })
                else { return }
                Task { await self.viewModel.setNotificationPreference(option) }
            }
        )
    }

    // MARK: - Collaborators

    /// The owner row for a collaboration upload: a stacked avatar cluster and the
    /// credited channel names, tapping either the row or the trailing pill opens
    /// the "Collaborators" picker with a Subscribe + bell per channel.
    private func collaboratorsRow(_ collaborators: [VideoCollaborator]) -> some View {
        let allSubscribed = collaborators.allSatisfy {
            self.viewModel.isSubscribed(toCollaborator: $0.channelId)
        }
        return HStack(spacing: 12) {
            Button {
                self.showsCollaborators = true
            } label: {
                HStack(spacing: 10) {
                    CollaboratorAvatarStack(urls: collaborators.compactMap(\.avatarURL))
                    self.collaboratorNames(collaborators)
                        .font(.system(size: 13))
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if self.hasPersonalAccount {
                Button {
                    self.showsCollaborators = true
                } label: {
                    Text(allSubscribed
                        ? String(localized: "Subscribed")
                        : String(localized: "Subscribe"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(allSubscribed ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
                        .padding(.horizontal, 16)
                        .frame(height: 36)
                        .compatGlass(
                            interactive: true,
                            tint: allSubscribed ? nil : Self.brandAccent,
                            in: Capsule()
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)
        }
        .popover(isPresented: self.$showsCollaborators, arrowEdge: .bottom) {
            CollaboratorsPopover(
                collaborators: collaborators,
                viewModel: self.viewModel,
                showsControls: self.hasPersonalAccount
            )
        }
    }

    /// The credited channel names joined the way YouTube shows them — "A and B",
    /// each followed by its verified badge.
    private func collaboratorNames(_ collaborators: [VideoCollaborator]) -> Text {
        var result = Text("")
        for (index, collaborator) in collaborators.enumerated() {
            if index > 0 {
                let separator = index == collaborators.count - 1
                    ? " \(String(localized: "and")) "
                    : ", "
                result = result + Text(separator).foregroundColor(.secondary)
            }
            result = result + Text(collaborator.name).fontWeight(.semibold)
            if collaborator.isVerified {
                result = result + Text(" ")
                    + Text(Image(systemName: "checkmark.seal.fill")).foregroundColor(.secondary)
            }
        }
        return result
    }

    // MARK: - Chapters

    /// Seek target chosen in `WatchChaptersSection` (which gates tappability
    /// on the player state, so no re-guard is needed here).
    private func seekToChapter(_ chapter: YouTubeChapter) {
        if self.youtubePlayer.currentVideo?.videoId != self.video.videoId {
            self.startOrAdoptPlayback(startAt: chapter.startTime)
            return
        }
        self.youtubePlayer.seek(to: chapter.startTime)
    }

    // MARK: - Related Column

    /// The queue the transport/up-next follows: the endless Mix (each track
    /// carrying the mix context so auto-advance keeps the mix) when one is
    /// playing, otherwise the related rail.
    private var upNextQueue: [YouTubeVideo] {
        let mix = self.viewModel.data.mixVideos
        guard !mix.isEmpty else { return self.viewModel.data.related }
        return mix.map { $0.inMix(self.viewModel.data.mixPlaylistId) }
    }

    private var relatedColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch self.viewModel.loadingState {
            case .idle, .loading:
                self.relatedHeader
                self.relatedSkeleton
            case let .error(error):
                self.relatedHeader
                Text(error.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .loaded, .loadingMore:
                if !self.viewModel.data.mixVideos.isEmpty {
                    self.mixBox
                }
                self.relatedHeader
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(self.viewModel.data.related) { related in
                        NavigationLink(value: YouTubeRoute.watch(related)) {
                            RelatedVideoRow(video: related)
                        }
                        .buttonStyle(.interactiveRow)
                    }
                }
            }
        }
    }

    private var relatedHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Related", comment: "Related videos section header")
                .font(.title3.bold())
            Spacer(minLength: 12)
            self.autoplayToggle
        }
    }

    /// YouTube-style "Autoplay" switch: when on, a finished video advances to the
    /// next suggested video. Off by default. Lives in the related header, like
    /// YouTube's up-next autoplay toggle.
    private var autoplayToggle: some View {
        Toggle(isOn: Binding(
            get: { self.settings.youtubeAutoplayEnabled },
            set: { self.settings.youtubeAutoplayEnabled = $0 }
        )) {
            Text("Autoplay", comment: "Toggle: automatically play the next suggested video")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .fixedSize()
    }

    private var relatedSkeleton: some View {
        ForEach(0 ..< 5, id: \.self) { _ in
            HStack(spacing: 12) {
                SkeletonView.rectangle(cornerRadius: 8)
                    .frame(width: 140, height: 79)
                VStack(alignment: .leading, spacing: 6) {
                    SkeletonView.rectangle(cornerRadius: 4)
                        .frame(width: 160, height: 12)
                    SkeletonView.rectangle(cornerRadius: 4)
                        .frame(width: 100, height: 10)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// Byline + "N/total" position under the queue title (either may be absent).
    private var mixBoxSubtitle: String? {
        let parts = [self.viewModel.data.mixDescription, self.viewModel.data.mixPosition]
            .compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The Mix's own boxed panel (title + "Mixes are playlists YouTube makes for
    /// you" + the endless queue), mirroring YouTube's up-next Mix card: a
    /// fixed-height, internally-scrolling list with the current track
    /// highlighted. The list is whatever YouTube returned for this video, so it
    /// updates on its own as you move through the mix.
    private var mixBox: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(self.viewModel.data.mixTitle ?? String(localized: "Mix"))
                    .font(.headline)
                    .lineLimit(2)
                if let subtitle = self.mixBoxSubtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(self.viewModel.data.mixVideos) { mixVideo in
                        NavigationLink(
                            value: YouTubeRoute.watch(
                                mixVideo.inMix(self.viewModel.data.mixPlaylistId)
                            )
                        ) {
                            RelatedVideoRow(video: mixVideo)
                                .padding(6)
                                .background(
                                    mixVideo.videoId == self.video.videoId
                                        ? Color.accentColor.opacity(0.22)
                                        : Color.clear,
                                    in: .rect(cornerRadius: 8)
                                )
                        }
                        .buttonStyle(.interactiveRow)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 340)
        }
        .compatGlass(interactive: false, tint: nil, in: .rect(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Comments

    private var commentsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Comments", comment: "Comments section header")
                    .font(.title3.bold())

                Spacer()

                if self.viewModel.canSortComments {
                    Menu {
                        Button {
                            Task { await self.viewModel.setCommentSort(.top) }
                        } label: {
                            if self.viewModel.commentSort == .top {
                                Label("Top comments", systemImage: "checkmark")
                            } else {
                                Text("Top comments", comment: "Comment sort: most relevant")
                            }
                        }
                        Button {
                            Task { await self.viewModel.setCommentSort(.newest) }
                        } label: {
                            if self.viewModel.commentSort == .newest {
                                Label("Newest first", systemImage: "checkmark")
                            } else {
                                Text("Newest first", comment: "Comment sort: most recent")
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "line.3.horizontal.decrease")
                                .font(.system(size: 11))
                            Text("Sort by", comment: "Comment sort menu label")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }

            self.commentComposer

            // Comment search
            let filteredComments = self.commentSearchQuery.trimmingCharacters(in: .whitespaces).isEmpty
                ? self.viewModel.comments
                : self.viewModel.comments.filter { comment in
                    comment.text.localizedCaseInsensitiveContains(self.commentSearchQuery)
                }

            if !self.viewModel.comments.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField(
                        String(localized: "Search comments…"),
                        text: self.$commentSearchQuery
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    if !self.commentSearchQuery.isEmpty {
                        Button {
                            self.commentSearchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.08))
                }
            }

            if filteredComments.isEmpty, !self.commentSearchQuery.isEmpty {
                Text("No matching comments.", comment: "Empty comment search")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if self.viewModel.comments.isEmpty, !self.viewModel.isLoadingComments {
                Text("No comments yet.", comment: "Empty comments section")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(filteredComments) { comment in
                        CommentThread(comment: comment, viewModel: self.viewModel, allowsActions: self.hasPersonalAccount)
                    }
                }
            }

            if self.viewModel.isLoadingComments {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            } else if self.viewModel.canLoadMoreComments {
                Button {
                    Task {
                        await self.viewModel.loadMoreComments()
                    }
                } label: {
                    Text("Show more comments", comment: "Load more comments button")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Self.brandAccent, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.commentsSection)
    }

    // MARK: - Live Chat

    /// The live-chat panel. `height` sizes the scroll area so it can match the
    /// video height when shown beside it, or use a fixed height when stacked.
    private func liveChatSection(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Circle()
                    .fill(.red)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text("Live chat", comment: "Live chat panel header")
                    .font(.title3.bold())
            }

            Group {
                if self.viewModel.liveChatMessages.isEmpty {
                    VStack(spacing: 8) {
                        if self.viewModel.liveChatLoaded {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.largeTitle)
                                .foregroundStyle(.tertiary)
                            Text("No messages yet", comment: "Empty live chat state")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(self.viewModel.liveChatMessages) { message in
                                    LiveChatRow(message: message)
                                        .id(message.id)
                                }
                                Color.clear
                                    .frame(height: 1)
                                    .id("live-chat-bottom")
                            }
                            .padding(10)
                        }
                        .frame(height: height)
                        .onChange(of: self.viewModel.liveChatMessages.count) { _, _ in
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo("live-chat-bottom", anchor: .bottom)
                            }
                        }
                        .onAppear {
                            proxy.scrollTo("live-chat-bottom", anchor: .bottom)
                        }
                    }
                }
            }
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.06))
            }

            if self.viewModel.canSendLiveChat {
                self.liveChatComposer
            }
        }
    }

    private var liveChatComposer: some View {
        HStack(spacing: 8) {
            TextField(
                String(localized: "Chat…", comment: "Live chat message field placeholder"),
                text: self.$liveChatDraft,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .lineLimit(1 ... 3)
            .onSubmit { self.sendLiveChatDraft() }

            Button(action: self.sendLiveChatDraft) {
                if self.viewModel.isSendingLiveChat {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Self.brandAccent)
                }
            }
            .buttonStyle(.plain)
            .disabled(
                self.viewModel.isSendingLiveChat
                    || self.liveChatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
            .accessibilityLabel(String(localized: "Send chat message"))
        }
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.08))
        }
    }

    private func sendLiveChatDraft() {
        let text = self.liveChatDraft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            if await self.viewModel.sendLiveChatMessage(text: text) {
                self.liveChatDraft = ""
            }
        }
    }

    private var commentComposer: some View {
        HStack(spacing: 10) {
            TextField(
                self.hasPersonalAccount && self.viewModel.canComment
                    ? String(localized: "Add a comment…")
                    : String(localized: "Sign in to comment"),
                text: self.$commentDraft
            )
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(.quaternary.opacity(0.5), in: Capsule())
            .disabled(!self.hasPersonalAccount || !self.viewModel.canComment)
            .onSubmit {
                self.submitComment()
            }
            .accessibilityIdentifier(AccessibilityID.YouTubeContent.commentField)

            Button {
                self.submitComment()
            } label: {
                Group {
                    if self.viewModel.isPostingComment {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .frame(width: 30, height: 30)
                .foregroundStyle(self.hasCommentDraft ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .compatGlass(
                    interactive: true,
                    tint: self.hasCommentDraft && self.viewModel.canComment ? Self.brandAccent : nil,
                    in: Circle()
                )
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(
                !self.hasPersonalAccount
                    || !self.viewModel.canComment
                    || self.viewModel.isPostingComment
                    || self.commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
            .accessibilityLabel(String(localized: "Post comment"))
            .accessibilityIdentifier(AccessibilityID.YouTubeContent.commentPostButton)
        }
    }

    private var hasPersonalAccount: Bool {
        self.authService.hasPersonalAccount
    }

    /// Whether the composer holds postable text (drives the send accent).
    private var hasCommentDraft: Bool {
        !self.commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitComment() {
        let draft = self.commentDraft
        Task {
            if await self.viewModel.postComment(text: draft) {
                self.commentDraft = ""
            }
        }
    }
}

// MARK: - WatchAmbientBackground

/// Hosts the ambient backdrop and owns every playback-progress read it needs.
///
/// Deliberately a separate child view: with `@Observable` tracking, the view
/// whose BODY reads `progress`/`duration` is the one invalidated by the 1 Hz
/// bridge updates. Keeping those reads out of `YouTubeWatchView.body` means
/// the watch page (metadata, comments, related) no longer re-evaluates every
/// second during playback — only this tiny host does.
private struct WatchAmbientBackground: View {
    let video: YouTubeVideo

    @Environment(YouTubePlayerService.self) private var youtubePlayer
    @State private var settings = SettingsManager.shared

    var body: some View {
        AmbientVideoBackdrop(
            videoId: self.video.videoId,
            thumbnailURL: self.video.thumbnailURL,
            style: self.settings.resolvedAmbientStyle,
            liveFraction: self.liveFraction,
            storyboardSpec: self.storyboardSpec
        )
        .ignoresSafeArea()
    }

    private var isCurrentVideo: Bool {
        self.youtubePlayer.currentVideo?.videoId == self.video.videoId
    }

    /// 0…1 playback position, only while THIS view's video is the one playing,
    /// for the `.live` storyboard color. `nil` otherwise (guards NaN when
    /// duration is still 0 at cold load).
    private var liveFraction: Double? {
        guard self.isCurrentVideo, self.youtubePlayer.duration > 0 else { return nil }
        return min(max(self.youtubePlayer.progress / self.youtubePlayer.duration, 0), 1)
    }

    /// Storyboard spec for the fine-grained `.live` color, but only while THIS
    /// view's video is the one playing — so a previous video's sheets never
    /// tint a newly-opened watch page.
    private var storyboardSpec: String? {
        guard self.isCurrentVideo else { return nil }
        return self.youtubePlayer.storyboardSpec
    }
}

// MARK: - WatchChaptersSection

/// The chapters rail, extracted so the active-chapter highlight's 1 Hz
/// `progress` reads invalidate only this section — not the whole watch page
/// (see `WatchAmbientBackground` for the observation-scoping rationale).
private struct WatchChaptersSection: View {
    let chapters: [YouTubeChapter]
    let videoId: String
    let onSeek: (YouTubeChapter) -> Void

    @Environment(YouTubePlayerService.self) private var youtubePlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Chapters", comment: "Video chapters section header")
                .font(.title3.bold())

            CarouselShelf(
                accessibilityLabel: String(localized: "Video chapters"),
                pageFraction: 0.82,
                showsControls: true,
                controlVerticalAlignment: .center,
                contentInset: 0
            ) {
                LazyHStack(alignment: .top, spacing: 10) {
                    ForEach(self.chapters) { chapter in
                        Button {
                            self.onSeek(chapter)
                        } label: {
                            ChapterCard(chapter: chapter, isActive: self.isActiveChapter(chapter))
                        }
                        .buttonStyle(.interactiveRow)
                        .accessibilityLabel(
                            String(localized: "Jump to chapter: \(chapter.title)")
                        )
                        .disabled(!self.canSeekToChapter(chapter))
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.chaptersSection)
    }

    private func canSeekToChapter(_ chapter: YouTubeChapter) -> Bool {
        if let chapterVideoId = chapter.videoId, chapterVideoId != self.videoId {
            return false
        }
        guard self.youtubePlayer.currentVideo?.videoId == self.videoId else {
            return true
        }
        return self.youtubePlayer.duration > 0
            && !self.youtubePlayer.isPlaybackLoading
            && !self.youtubePlayer.isShowingAd
    }

    private func isActiveChapter(_ chapter: YouTubeChapter) -> Bool {
        guard self.youtubePlayer.currentVideo?.videoId == self.videoId else { return false }
        let currentTime = self.youtubePlayer.progress
        guard currentTime >= chapter.startTime else { return false }
        if let endTime = chapter.endTime {
            return currentTime < endTime
        }
        guard let index = self.chapters.firstIndex(where: { $0.id == chapter.id }) else {
            return false
        }
        let nextIndex = self.chapters.index(after: index)
        guard nextIndex < self.chapters.endIndex else { return true }
        return currentTime < self.chapters[nextIndex].startTime
    }
}

// MARK: - CommentThread

/// A comment with its action row (like/dislike, replies) and, when
/// expanded, its indented reply thread.
private struct CommentThread: View {
    let comment: YouTubeComment
    let viewModel: YouTubeWatchViewModel
    let allowsActions: Bool

    @State private var showsReplies = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CommentRow(
                comment: self.comment,
                isLiked: self.viewModel.likedComments.contains(self.comment.id),
                isDisliked: self.viewModel.dislikedComments.contains(self.comment.id),
                onLike: {
                    Task {
                        await self.viewModel.likeComment(self.comment)
                    }
                },
                onDislike: {
                    Task {
                        await self.viewModel.dislikeComment(self.comment)
                    }
                },
                allowsActions: self.allowsActions
            )

            if self.comment.repliesContinuation != nil {
                Button {
                    self.showsReplies.toggle()
                    if self.showsReplies {
                        Task {
                            await self.viewModel.loadReplies(for: self.comment)
                        }
                    }
                } label: {
                    Label(
                        self.showsReplies
                            ? String(localized: "Hide replies")
                            : String(localized: "View replies"),
                        systemImage: self.showsReplies ? "chevron.up" : "chevron.down"
                    )
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .padding(.leading, 38)
            }

            if self.showsReplies {
                if self.viewModel.loadingReplies.contains(self.comment.id) {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.leading, 38)
                } else if let replies = self.viewModel.repliesByComment[self.comment.id] {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(replies) { reply in
                            CommentRow(
                                comment: reply,
                                isLiked: self.viewModel.likedComments.contains(reply.id),
                                isDisliked: self.viewModel.dislikedComments.contains(reply.id),
                                onLike: {
                                    Task {
                                        await self.viewModel.likeComment(reply)
                                    }
                                },
                                onDislike: {
                                    Task {
                                        await self.viewModel.dislikeComment(reply)
                                    }
                                },
                                allowsActions: self.allowsActions
                            )
                        }
                    }
                    .padding(.leading, 38)
                }
            }
        }
    }
}

// MARK: - Comment timestamp links

/// Parses a `M:SS`, `MM:SS`, or `H:MM:SS` timestamp token into total seconds.
func parseCommentTimestamp(_ token: String) -> Int? {
    let parts = token.split(separator: ":").map { Int($0) }
    guard !parts.contains(nil) else { return nil }
    let nums = parts.compactMap(\.self)
    switch nums.count {
    case 2: return nums[0] * 60 + nums[1]
    case 3: return nums[0] * 3600 + nums[1] * 60 + nums[2]
    default: return nil
    }
}

/// Builds an attributed comment where in-range timestamps (`M:SS` / `H:MM:SS`)
/// become `kasetseek://<seconds>` links, matching YouTube. Timestamps past the
/// video's duration stay plain text; when the duration is unknown (0) nothing
/// is linked. Character offsets (not UTF-16) are used so emoji don't shift the
/// link ranges.
func commentAttributedText(_ text: String, duration: TimeInterval) -> AttributedString {
    var result = AttributedString(text)
    guard duration > 0 else { return result }
    let pattern = "(?<![\\d:])\\d{1,2}:\\d{2}(?::\\d{2})?(?![\\d:])"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
    let ns = text as NSString
    for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        guard let stringRange = Range(match.range, in: text) else { continue }
        let token = String(text[stringRange])
        guard let seconds = parseCommentTimestamp(token), Double(seconds) <= duration else { continue }

        let startOffset = text.distance(from: text.startIndex, to: stringRange.lowerBound)
        let chars = result.characters
        guard let start = chars.index(chars.startIndex, offsetBy: startOffset, limitedBy: chars.endIndex),
              let end = chars.index(start, offsetBy: token.count, limitedBy: chars.endIndex)
        else { continue }
        result[start ..< end].link = URL(string: "kasetseek://\(seconds)")
        result[start ..< end].foregroundColor = .accentColor
    }
    return result
}

// MARK: - LiveChatRow

/// One live-chat message: small avatar, author (colored by role), and the
/// message text. Author role badges (owner/moderator/member/verified) match
/// YouTube's live chat.
private struct LiveChatRow: View {
    let message: YouTubeLiveChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            self.avatar

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(self.message.author)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(self.authorColor)
                        .lineLimit(1)

                    if self.message.isOwner {
                        self.badge("crown.fill", .yellow)
                    }
                    if self.message.isModerator {
                        self.badge("wrench.adjustable.fill", .blue)
                    }
                    if self.message.isMember {
                        self.badge("star.fill", .green)
                    }
                    if self.message.isVerified {
                        self.badge("checkmark.seal.fill", .secondary)
                    }

                    if let timestampText = self.message.timestampText {
                        Text(timestampText)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }

                Text(self.message.message)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var authorColor: Color {
        if self.message.isOwner { return .yellow }
        if self.message.isModerator { return .blue }
        if self.message.isMember { return .green }
        return .secondary
    }

    private var avatar: some View {
        CachedAsyncImage(
            url: self.message.authorAvatarURL,
            targetSize: CGSize(width: 24, height: 24)
        ) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            Circle()
                .fill(.quaternary)
        }
        .frame(width: 24, height: 24)
        .clipShape(.circle)
    }

    private func badge(_ systemName: String, _ color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 9))
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }
}

// MARK: - CommentRow

/// One comment: avatar, author + time, text, and working like/dislike.
/// The author (avatar/name) navigates to their channel.
private struct CommentRow: View {
    let comment: YouTubeComment
    let isLiked: Bool
    let isDisliked: Bool
    let onLike: () -> Void
    let onDislike: () -> Void
    let allowsActions: Bool

    @Environment(YouTubePlayerService.self) private var youtubePlayer

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            self.authorLink {
                self.avatar
            }

            VStack(alignment: .leading, spacing: 3) {
                if self.comment.isPinned {
                    Label("Pinned", systemImage: "pin.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 5) {
                    self.authorLink { self.authorNameLabel }

                    if self.comment.authorIsVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .help(Text("Verified", comment: "Verified channel badge"))
                    }

                    if let badgeURL = self.comment.memberBadgeThumbnailURL {
                        CachedAsyncImage(url: badgeURL, targetSize: CGSize(width: 16, height: 16)) { image in
                            image.resizable().aspectRatio(contentMode: .fit)
                        } placeholder: {
                            Image(systemName: "star.circle.fill").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        .frame(width: 16, height: 16)
                        .help(Text(self.comment.memberBadgeTooltip ?? String(localized: "Member", comment: "Channel member badge")))
                    }

                    if let publishedText = self.comment.publishedText {
                        Text(publishedText)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }

                Text(commentAttributedText(self.comment.text, duration: self.youtubePlayer.duration))
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .environment(\.openURL, OpenURLAction { url in
                        guard url.scheme == "kasetseek", let host = url.host, let seconds = Double(host)
                        else { return .systemAction }
                        self.youtubePlayer.seek(to: seconds)
                        return .handled
                    })

                HStack(spacing: 14) {
                    Button(action: self.onLike) {
                        HStack(spacing: 4) {
                            Image(systemName: self.isLiked ? "hand.thumbsup.fill" : "hand.thumbsup")
                                .font(.system(size: 11))
                            if let likeCountText = self.comment.likeCountText, !likeCountText.isEmpty {
                                Text(likeCountText)
                                    .font(.system(size: 11))
                            }
                        }
                        .foregroundStyle(self.isLiked ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
                    }
                    .buttonStyle(.plain)
                    .disabled(!self.allowsActions || self.comment.likeAction == nil)
                    .accessibilityLabel(String(localized: "Like comment"))

                    Button(action: self.onDislike) {
                        Image(systemName: self.isDisliked ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                            .font(.system(size: 11))
                            .foregroundStyle(self.isDisliked ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
                    }
                    .buttonStyle(.plain)
                    .disabled(!self.allowsActions || self.comment.dislikeAction == nil)
                    .accessibilityLabel(String(localized: "Dislike comment"))

                    if self.comment.isHeartedByCreator {
                        self.creatorHeart
                    }
                }
                .padding(.top, 2)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// The author's name. The video's creator is shown in a filled accent pill,
    /// matching YouTube's highlighting of the uploader's own comments.
    @ViewBuilder private var authorNameLabel: some View {
        if self.comment.authorIsChannelOwner {
            Text(self.comment.author)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary))
        } else {
            Text(self.comment.author)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }

    /// YouTube's "hearted by creator" marker: the creator's avatar with a small
    /// heart, shown on comments the uploader liked.
    @ViewBuilder private var creatorHeart: some View {
        ZStack(alignment: .bottomTrailing) {
            CachedAsyncImage(url: self.comment.creatorHeartAvatarURL, targetSize: CGSize(width: 16, height: 16)) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Circle().fill(.quaternary)
            }
            .frame(width: 16, height: 16)
            .clipShape(.circle)

            Image(systemName: "heart.fill")
                .font(.system(size: 7))
                .foregroundStyle(.red)
                .padding(1)
                .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                .offset(x: 3, y: 3)
        }
        .help(Text("Hearted by creator", comment: "Comment hearted by the video's creator"))
    }

    /// Wraps content in a channel link when the author's channel is known.
    @ViewBuilder
    private func authorLink(@ViewBuilder content: () -> some View) -> some View {
        if let channelId = self.comment.authorChannelId {
            NavigationLink(value: YouTubeRoute.channel(channelId: channelId)) {
                content()
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            content()
        }
    }

    private var avatar: some View {
        CachedAsyncImage(
            url: self.comment.authorAvatarURL,
            targetSize: CGSize(width: 28, height: 28)
        ) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            Circle()
                .fill(.quaternary)
                .overlay {
                    Image(systemName: "person.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
        }
        .frame(width: 28, height: 28)
        .clipShape(.circle)
    }
}

// MARK: - ChapterCard

private struct ChapterCard: View {
    let chapter: YouTubeChapter
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            self.thumbnail
                .frame(width: 160, height: 90)
                .clipShape(.rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(self.chapter.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(self.chapter.timeText ?? Self.formatTime(self.chapter.startTime))
                    .font(.caption)
                    .foregroundStyle(self.isActive ? YouTubeWatchView.brandAccent : .secondary)
            }
        }
        .padding(8)
        .frame(width: 176, alignment: .leading)
        .background(self.isActive ? YouTubeWatchView.brandAccent.opacity(0.14) : Color.secondary.opacity(0.08), in: .rect(cornerRadius: 12))
        .contentShape(.rect(cornerRadius: 10))
    }

    private var thumbnail: some View {
        CachedAsyncImage(
            url: self.chapter.thumbnailURL,
            targetSize: CGSize(width: 192, height: 108)
        ) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            Rectangle()
                .fill(.quaternary)
                .overlay {
                    Image(systemName: "text.append")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
        }
    }

    private static func formatTime(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - RelatedVideoRow

/// Compact related-rail row sized for the right column.
private struct RelatedVideoRow: View {
    let video: YouTubeVideo

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VideoThumbnailView(video: self.video)
                .frame(width: 140)

            VStack(alignment: .leading, spacing: 3) {
                Text(self.video.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if let channelName = self.video.channelName {
                    Text(channelName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let viewCountText = self.video.viewCountText {
                    Text(viewCountText)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - AccessibilityID Additions

extension AccessibilityID.YouTubeContent {
    static let watchSurface = "youtubeContent.watchSurface"
    static let chaptersSection = "youtubeContent.chaptersSection"
    static let commentsSection = "youtubeContent.commentsSection"
    static let commentField = "youtubeContent.commentField"
    static let commentPostButton = "youtubeContent.commentPostButton"
    static let subscribeButton = "youtubeContent.subscribeButton"
    static let watchMoveHere = "youtubeContent.watchMoveHere"
}

// MARK: - CollaboratorAvatarStack

/// Overlapping avatar cluster for a collaboration upload's owner row, matching
/// YouTube's stacked-avatar look.
private struct CollaboratorAvatarStack: View {
    let urls: [URL]

    var body: some View {
        HStack(spacing: -10) {
            ForEach(Array(self.urls.prefix(3).enumerated()), id: \.offset) { _, url in
                CachedAsyncImage(
                    url: url,
                    targetSize: CGSize(width: 36, height: 36)
                ) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Circle().fill(.quaternary)
                }
                .frame(width: 32, height: 32)
                .clipShape(.circle)
                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
            }
        }
    }
}

// MARK: - CollaboratorsPopover

/// The "Collaborators" picker for a multi-channel upload: each credited channel
/// with its own Subscribe button and notification "bell".
private struct CollaboratorsPopover: View {
    let collaborators: [VideoCollaborator]
    let viewModel: YouTubeWatchViewModel
    let showsControls: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Collaborators", comment: "Header for the multi-channel collaboration picker")
                .font(.headline)

            ForEach(self.collaborators) { collaborator in
                CollaboratorRow(
                    collaborator: collaborator,
                    viewModel: self.viewModel,
                    showsControls: self.showsControls
                )
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

// MARK: - CollaboratorRow

/// A single collaborator inside the picker: avatar, name + verified badge,
/// handle · subscribers, and a Subscribe/bell control mirroring the watch page's
/// single-channel one.
private struct CollaboratorRow: View {
    @MainActor static var brandAccent: Color { SettingsManager.shared.accentColor }

    let collaborator: VideoCollaborator
    let viewModel: YouTubeWatchViewModel
    let showsControls: Bool

    private var isSubscribed: Bool {
        self.viewModel.isSubscribed(toCollaborator: self.collaborator.channelId)
    }

    private var preference: ChannelNotificationPreference? {
        self.viewModel.collaboratorNotification[self.collaborator.channelId]
    }

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(
                url: self.collaborator.avatarURL,
                targetSize: CGSize(width: 40, height: 40)
            ) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Circle().fill(.quaternary)
            }
            .frame(width: 40, height: 40)
            .clipShape(.circle)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(self.collaborator.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if self.collaborator.isVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                if let detail = self.collaborator.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if self.showsControls {
                self.control
            }
        }
    }

    @ViewBuilder
    private var control: some View {
        if self.isSubscribed, let preference {
            self.bellMenu(preference)
        } else {
            Button {
                Task { await self.viewModel.toggleSubscribed(collaborator: self.collaborator) }
            } label: {
                Text(self.isSubscribed
                    ? String(localized: "Subscribed")
                    : String(localized: "Subscribe"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(self.isSubscribed ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .compatGlass(
                        interactive: true,
                        tint: self.isSubscribed ? nil : Self.brandAccent,
                        in: Capsule()
                    )
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func bellMenu(_ preference: ChannelNotificationPreference) -> some View {
        Menu {
            Picker(String(localized: "Notifications"), selection: self.selection(preference)) {
                ForEach(preference.options) { option in
                    Label(option.label, systemImage: option.level.symbolName).tag(option.id)
                }
            }
            .pickerStyle(.inline)

            Divider()

            Button(role: .destructive) {
                Task { await self.viewModel.toggleSubscribed(collaborator: self.collaborator) }
            } label: {
                Label(preference.unsubscribeLabel, systemImage: "person.fill.xmark")
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: preference.currentLevel.symbolName)
                    .font(.system(size: 12))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .compatGlass(interactive: true, tint: nil, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "Notification settings"))
    }

    private func selection(_ preference: ChannelNotificationPreference) -> Binding<String> {
        Binding(
            get: { preference.current?.id ?? "" },
            set: { newID in
                guard let option = preference.options.first(where: { $0.id == newID }) else { return }
                Task {
                    await self.viewModel.setNotificationPreference(
                        option, forCollaborator: self.collaborator.channelId
                    )
                }
            }
        )
    }
}

// MARK: - FlowLayout

/// Left-to-right layout that wraps its subviews onto new lines when they don't
/// fit the available width — used so the watch action buttons flow onto
/// multiple lines instead of cramming into one row.
/// ponytail: leading-aligned chips only; that's all the action bar needs.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + lineSpacing
                totalWidth = max(totalWidth, rowWidth)
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth)
        return CGSize(width: min(totalWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, (x - bounds.minX) + size.width > bounds.width {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
