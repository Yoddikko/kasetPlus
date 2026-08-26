// swiftlint:disable file_length
import Foundation
import Observation

// MARK: - YouTubePlaybackOccurrence

struct YouTubePlaybackOccurrence: Hashable {
    let documentGeneration: UInt64
    let mediaGeneration: UInt64
}

// MARK: - YouTubeWatchPlaybackControlling

/// Playback command surface backing `YouTubePlayerService`.
/// The real implementation is `YouTubeWatchWebView`; tests inject a recorder.
@MainActor
protocol YouTubeWatchPlaybackControlling: AnyObject {
    func prepare(webKitManager: WebKitManager, playerService: YouTubePlayerService, usesCookieFreeDataStore: Bool)
    func loadVideo(videoId: String)
    func reloadVideo(videoId: String, resumeAt seconds: Double?)
    @discardableResult
    func cancelPendingLoad() -> Bool
    func playPause()
    func play()
    func pause()
    func skipAd(resumeAt: Double)
    func seek(to time: Double)
    func seekToLive()
    func seekWithRecovery(to seconds: Double)
    func cancelPendingRecoverySeek()
    func markCurrentPlaybackOccurrenceEnded()
    func setVolume(_ volume: Double)
    func showAirPlayPicker()
    func availableCaptionTracks() async -> [YouTubeCaptionTrack]
    func currentCaptionLanguageCode() async -> String?
    func setCaptionTrack(languageCode: String?)
    func availableAudioTracks() async -> [YouTubeAudioTrack]
    func currentAudioTrackId() async -> String?
    func setAudioTrack(id: String)
    func availableQualityLevels() async -> [String]
    func currentQualityLevel() async -> String?
    func setQualityLevel(_ level: String)
    func storyboardSpec(expectedVideoId: String?) async -> String?
    func tearDown()
}

// MARK: - YouTubeWatchWebView + YouTubeWatchPlaybackControlling

extension YouTubeWatchWebView: YouTubeWatchPlaybackControlling {
    func prepare(webKitManager: WebKitManager, playerService: YouTubePlayerService, usesCookieFreeDataStore: Bool) {
        _ = self.getWebView(
            webKitManager: webKitManager,
            playerService: playerService,
            usesCookieFreeDataStore: usesCookieFreeDataStore
        )
    }
}

// MARK: - YouTubePlayerService

/// Playback state and control for regular YouTube videos.
///
/// Parallel to `PlayerService` (music) — that service is untouched. The
/// actual playback happens in `YouTubeWatchWebView`; this service owns the
/// observable state, command surface, and the docked/floating placement of
/// the extracted video surface.
@MainActor
@Observable
final class YouTubePlayerService {
    // MARK: - State

    /// The video currently loaded for playback (nil when playback is closed).
    private(set) var currentVideo: YouTubeVideo?

    /// Monotonic generation bumped by EVERY change to what/how-much was watched:
    /// a video starting (`play`), a skip to another (`advance`), a finish
    /// (`handleVideoEnded`), the page drifting to a different video
    /// (`updatePlaybackState`), and `stop()` tearing down a video that had
    /// accrued progress. It is a pure SIGNAL — set-only here, never consumed by
    /// readers. Home keeps its OWN watermark of the last generation it reflected
    /// and rebuilds Continue Watching whenever this is ahead of that watermark.
    ///
    /// Deliberately over-signals: a redundant rebuild is cheap and correct, while
    /// a missed signal leaves the rail stale. This inverts the old fragile model
    /// (multiple counters, eagerly consumed at the wrong moment) where every new
    /// watch path needed a matching "remember to bump / don't consume early" fix.
    private(set) var watchActivityGeneration = 0

    /// Like `watchActivityGeneration` but bumped only when a watch CONCLUDES with
    /// progress to reflect — a skip (`advance`), finish (`handleVideoEnded`),
    /// drift (`updatePlaybackState`), or `stop()` of a video with accrued
    /// progress — NOT on a bare `play` start. The Home-root observer (which fires
    /// without any navigation, e.g. a floating video finishing while the user
    /// sits on Home) keys on THIS so a bare start, which has no new resume state
    /// yet, can't trigger a premature rebuild that advances the watermark and
    /// then swallows the real progress. The value passed to the view model is
    /// still `watchActivityGeneration`; this only decides *when* that observer
    /// fires. (Navigation-return observers use `watchActivityGeneration` directly:
    /// by the time the user navigates back, progress has accrued.)
    private(set) var watchConclusionGeneration = 0

    /// True once the current video has already signalled its conclusion (a
    /// natural finish via `handleVideoEnded`). It prevents `stop()` — which often
    /// follows a finish when the user closes the floating window — from
    /// re-signalling the same already-finished video as a fresh partial-watch
    /// conclusion (a double bump that would cancel/restart the refresh the finish
    /// just scheduled). Reset whenever a new video becomes current.
    private var currentWatchConcluded = false

    /// Document/media occurrence currently represented by bridge state. This is
    /// finer-grained than `currentWatchConcluded`: same-document replay can start
    /// a new occurrence for the same video before an older ended task executes.
    @ObservationIgnored private(set) var currentPlaybackOccurrence: YouTubePlaybackOccurrence?
    @ObservationIgnored private var lastEndedPlaybackOccurrence: YouTubePlaybackOccurrence?
    @ObservationIgnored private var lastResumeIssuedAtMilliseconds: Double?
    @ObservationIgnored private var isAutoplayTransitionPending = false
    @ObservationIgnored private var shouldRecoverAutoplayTransitionOnResume = false
    @ObservationIgnored private var autoplayRecoveryRequestGeneration: UInt64 = 0

    /// Whether the video is currently playing.
    private(set) var isPlaying = false

    /// The page has reported ready media in a paused state. This distinguishes a
    /// settled autoplay failure from the pre-media loading gap.
    @ObservationIgnored private var hasObservedPausedMedia = false

    private enum DesiredPlaybackIntent: Equatable {
        case playing
        case paused
    }

    /// The single authoritative play/pause intent. Observer pauses can be
    /// transient while a requested document loads, so only explicit terminal
    /// actions clear this; an accepted playing update restores it for autoplay.
    @ObservationIgnored private var desiredPlaybackIntent: DesiredPlaybackIntent = .paused

    /// Rejects remote-command callbacks captured before a newer native video action.
    @ObservationIgnored var youtubePlaybackIntentIssuedAtMilliseconds: Double = 0
    @ObservationIgnored var youtubeRemoteCommandIntentIssuedAtMilliseconds: Double?
    @ObservationIgnored var youtubePlaybackIntentGeneration: UInt64 = 0

    /// Explicit native pause dominates late playing samples until the next native
    /// resume/new-watch intent. Natural end is intentionally separate so genuine
    /// same-document autoplay can still become authoritative.
    @ObservationIgnored private var isExplicitPauseIntentActive = false
    @ObservationIgnored private var isAwaitingResumeConfirmation = false

    private struct ExplicitStartTarget {
        let videoId: String
        let seconds: Double
    }

    private struct PendingUserSeekTarget {
        let videoId: String
        let seconds: Double
    }

    /// An explicit `play(startAt:)` target remains available to native recovery
    /// until real content reports an authoritative position.
    @ObservationIgnored private var pendingExplicitStartTarget: ExplicitStartTarget?

    /// A direct user seek stays authoritative until the bridge acknowledges the
    /// exact target, including across identity or process reloads.
    @ObservationIgnored private var pendingUserSeekTarget: PendingUserSeekTarget?

    /// A paused video does not need an immediate identity-switch reload, because
    /// there is no active playback to re-attribute. Defer the reload until the
    /// user explicitly resumes so loading YouTube's autoplaying watch page cannot
    /// create watch activity for content the user left paused.
    var pendingPausedIdentityReloadVideoId: String?
    var pendingPausedIdentityReloadResumeAt: Double?
    var userUpdatedPendingPausedIdentityReloadSeek = false
    private var isIdentityReloadInFlight = false
    private var pausedIdentityReloadAwaitingFirstUpdate = false

    /// Current position in seconds.
    var progress: Double = 0

    /// Last observed playback position from genuine CONTENT (not an ad). Used as
    /// the resume target for an identity-switch reload so a switch during a
    /// preroll/midroll ad doesn't resume the content near 0 (the ad element's
    /// time). Service-internal, written on every 1 Hz update — not observable
    /// so those writes don't invalidate views.
    @ObservationIgnored var lastNonAdContentProgress: Double = 0
    private var lastNonAdContentVideoId: String?

    /// Video length in seconds.
    private(set) var duration: Double = 0

    /// Last requested relative-seek target used to coalesce rapid repeated
    /// button presses while bridge state updates lag behind WebView commands.
    @ObservationIgnored var lastRelativeSeekTarget: Double?
    @ObservationIgnored var lastRelativeSeekIssuedAt: ContinuousClock.Instant?
    @ObservationIgnored var lastRelativeSeekVideoId: String?

    /// Whether an ad is currently showing on the watch page.
    private(set) var isShowingAd = false

    /// Whether the current ad can be skipped right now (YouTube's Skip button is
    /// present). Drives the on-video "Skip Ad" button so it only shows when
    /// clicking it will actually skip.
    private(set) var isAdSkippable = false

    /// Whether the current video is a live stream (reported by the observer).
    private(set) var isLive = false

    /// Whether live playback is at the live edge (within a few seconds of the
    /// seekable end). Drives the "LIVE" button's red/grey state.
    private(set) var isAtLiveEdge = false

    /// Whether the current video is waiting for the WebView to report playable media.
    private(set) var isPlaybackLoading = false

    /// Runtime liveness from the active media element. This covers videos whose
    /// feed model is incomplete, including URL launches and SPA drift.
    @ObservationIgnored var currentMediaIsLive = false

    @ObservationIgnored private var playbackLoadingTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var playbackLoadingGeneration: UInt64 = 0

    /// SponsorBlock segments for the current video ([start, end] in seconds, by category).
    /// Updated by the WebView observer when segments are fetched from the SponsorBlock API.
    var sponsorSegments: [SponsorSegment] = []

    /// Short-lived notice for the most recently auto-skipped SponsorBlock segment.
    private(set) var sponsorSkipNotice: SponsorSkipNotice?
    @ObservationIgnored private var sponsorSkipNoticeDismissTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSponsorSegments: (videoId: String, segments: [SponsorSegment])?
    @ObservationIgnored private var pendingSponsorSkip: (videoId: String, segment: SponsorSegment)?

    /// Clears SponsorBlock segments when a new video starts loading.
    func setSponsorSegments(_ segments: [SponsorSegment], videoId: String) {
        if self.currentVideo?.videoId == videoId {
            self.pendingSponsorSegments = nil
            self.sponsorSegments = segments
        } else {
            // The watch page can finish its SponsorBlock request before the
            // first STATE_UPDATE adopts a new SPA video in native state.
            self.pendingSponsorSegments = (videoId, segments)
        }
    }

    /// Surfaces an automatic SponsorBlock skip in the native player chrome.
    func handleSponsorBlockSkip(
        start: Double,
        end: Double,
        category: String,
        videoId: String
    ) {
        guard start.isFinite,
              end.isFinite,
              start >= 0,
              end > start,
              !category.isEmpty
        else { return }

        let segment = SponsorSegment(start: start, end: end, category: category)
        guard self.currentVideo?.videoId == videoId else {
            self.pendingSponsorSkip = (videoId, segment)
            return
        }
        self.presentSponsorBlockSkip(segment)
    }

    private func presentSponsorBlockSkip(_ segment: SponsorSegment) {
        let notice = SponsorSkipNotice(segment: segment)
        self.sponsorSkipNotice = notice
        self.sponsorSkipNoticeDismissTask?.cancel()
        self.sponsorSkipNoticeDismissTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            guard self?.sponsorSkipNotice?.id == notice.id else { return }
            self?.sponsorSkipNotice = nil
            self?.sponsorSkipNoticeDismissTask = nil
        }
    }

    /// Returns to the beginning of the last skipped segment. The WebView seek
    /// is tagged as explicit user intent so SponsorBlock lets it play through.
    func undoSponsorBlockSkip() {
        guard let notice = self.sponsorSkipNotice else { return }
        self.dismissSponsorBlockSkipNotice()
        self.seek(to: notice.segment.start)
    }

    func dismissSponsorBlockSkipNotice() {
        self.sponsorSkipNoticeDismissTask?.cancel()
        self.sponsorSkipNoticeDismissTask = nil
        self.sponsorSkipNotice = nil
    }

    private func applyPendingSponsorBlockState(for videoId: String) {
        if let pendingSponsorSegments, pendingSponsorSegments.videoId == videoId {
            self.sponsorSegments = pendingSponsorSegments.segments
        }
        self.pendingSponsorSegments = nil

        if let pendingSponsorSkip, pendingSponsorSkip.videoId == videoId {
            self.presentSponsorBlockSkip(pendingSponsorSkip.segment)
        }
        self.pendingSponsorSkip = nil
    }

    // MARK: - Return YouTube Dislikes

    /// RYD dislike count for the current video (nil = not yet fetched or unavailable).
    private(set) var rydDislikes: Int?
    /// RYD like count for the current video.
    private(set) var rydLikes: Int?
    /// Tracks which videoId we already fetched RYD data for (dedup).
    private var rydFetchVideoId: String?

    /// Formats an integer count to a compact string (e.g. 12345 → "12.3K").
    static func formatCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            let m = Double(count) / 1_000_000.0
            return String(format: m >= 100 ? "%.0fM" : (m >= 10 ? "%.1fM" : "%.2fM"), m)
        }
        if count >= 1000 {
            let k = Double(count) / 1000.0
            return String(format: k >= 100 ? "%.0fK" : (k >= 10 ? "%.1fK" : "%.2fK"), k)
        }
        return "\(count)"
    }

    // MARK: - DeArrow

    /// Shared toggle state — synced between watch view and player bar.
    var showsDearrowOriginal = false

    /// Toggles the inline lyrics section (watch view + player bar button).
    var showsLyrics = false

    /// Opens the download sheet from the player bar button.
    var showsDownloadSheet = false

    /// Whether the inline video surface is currently on screen in the watch
    /// page's scroll view. When it scrolls out of view, the docked bar comes
    /// back so playback stays controllable even with "controls on video" on.
    var inlineVideoOnScreen = false

    /// Current playback speed (0.5, 0.75, 1.0, 1.25, 1.5, 2.0).
    var playbackSpeed: Double = 1.0 {
        didSet {
            YouTubeWatchWebView.shared.setSpeed(self.playbackSpeed)
        }
    }

    /// True while an on-video control popover (Speed & Quality) is open. The
    /// overlay/fullscreen auto-hide checks this so opening the gear — which moves
    /// the pointer off the video surface — doesn't tear the controls, and the
    /// popover with them, back out. (#32/#33 interaction.)
    var isControlOverlayPinned = false

    /// Computed: the DeArrow title for the current video (from shared cache).
    var dearrowTitle: String? {
        guard let videoId = self.currentVideo?.videoId else { return nil }
        return DearrowCache.shared.hasDearrow(for: videoId)
            ? DearrowCache.shared.displayTitle(for: videoId, original: self.currentVideo?.title ?? "")
            : nil
    }

    /// The original title stored in the cache for toggle-back support.
    var dearrowOriginalTitle: String? {
        guard let videoId = self.currentVideo?.videoId else { return nil }
        return DearrowCache.shared.originalTitle(for: videoId)
    }

    func fetchReturnYouTubeDislikes(videoId: String) async {
        guard SettingsManager.shared.returnYouTubeDislikesEnabled,
              videoId != self.rydFetchVideoId
        else { return }

        self.rydFetchVideoId = videoId

        guard let url = URL(string: "https://returnyoutubedislikeapi.com/votes?videoId=\(videoId)") else {
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            self.rydDislikes = json["dislikes"] as? Int
            self.rydLikes = json["likes"] as? Int
        } catch {
            self.rydDislikes = nil
            self.rydLikes = nil
        }
    }

    /// Playback volume (0...1).
    var volume: Double = 1.0 {
        didSet {
            guard oldValue != self.volume else { return }
            self.playbackController.setVolume(self.volume)
        }
    }

    /// Where the extracted video surface currently lives.
    enum SurfaceLocation: Equatable {
        case none
        case inline
        case floating
    }

    /// Current surface placement. KasetApp observes this to open/close the
    /// floating window.
    private(set) var surfaceLocation: SurfaceLocation = .none

    /// The videoId of the WatchView that currently owns the inline surface.
    var activeInlineVideoId: String?

    /// The user's rating of the current video (optimistic; YouTube doesn't
    /// expose the initial rating cheaply, so this tracks local actions).
    private(set) var currentRating: YouTubeRating = .none

    /// Set when the floating window asks to dock back into the app.
    /// KasetApp brings the app to the video source; YouTubeContentView
    /// opens/adopts the watch view and consumes the request.
    private(set) var popInRequest: YouTubeVideo?

    /// Up-next candidates for skip-forward (related videos from the watch page).
    private(set) var upNext: [YouTubeVideo] = []

    /// The video queued to autoplay next, shown behind a countdown card after the
    /// current video finishes (YouTube-style). Nil when no autoplay is pending.
    private(set) var autoplayPendingVideo: YouTubeVideo?
    /// Whole seconds left on the autoplay countdown (counts `autoplayCountdownSeconds`→0);
    /// meaningful only while `autoplayPendingVideo` is set.
    private(set) var autoplayCountdownRemaining = 0
    @ObservationIgnored private var autoplayCountdownTask: Task<Void, Never>?
    /// How long the "up next" countdown card lingers before advancing.
    static let autoplayCountdownSeconds = 5

    /// Navigation chapters for the current video, loaded from the watch page's
    /// companion `next` response.
    private(set) var chapters: [YouTubeChapter] = []

    /// "Most replayed" heatmap samples for the current video, from the same
    /// `next` response. Empty when YouTube exposes no heatmap.
    private(set) var heatmap: [YouTubeHeatmapMarker] = []

    /// Videos played earlier this session, for skip-backward.
    private var history: [YouTubeVideo] = []

    /// Set when a skip changes the video while docked inline so
    /// YouTubeContentView can open the new video's watch view.
    private(set) var skipNavigationRequest: YouTubeVideo?

    /// Whether the current video was added to Watch Later this session.
    private(set) var isInWatchLater = false

    /// Whether the pop-out window is in fullscreen (set by its controller).
    var isWindowFullscreen = false

    /// Caption tracks available on the current watch page.
    private(set) var captionTracks: [YouTubeCaptionTrack] = []

    /// Language code of the active caption track (nil = captions off).
    private(set) var activeCaptionLanguageCode: String?

    /// Alternate audio tracks (dubbed languages) on the current watch page.
    /// Empty when the video has a single audio track.
    private(set) var audioTracks: [YouTubeAudioTrack] = []

    /// Id of the active audio track (nil until resolved).
    private(set) var activeAudioTrackId: String?

    /// Quality levels available on the current watch page.
    private(set) var qualityLevels: [String] = []

    /// The player's current quality level (the level YouTube actually resolved).
    private(set) var currentQuality: String?

    /// The quality the user explicitly pinned from the gear menu, or `nil` while
    /// left on **Auto** (the default). The menu checkmark follows this so Auto
    /// shows as selected until a fixed level is chosen, instead of following the
    /// auto-resolved `currentQuality` (which made e.g. 1080p look hand-picked).
    private(set) var userPinnedQuality: String?

    /// YouTube storyboard spec for the current video (drives the ambient
    /// backdrop's fine-grained live color). `nil` until fetched / unavailable.
    private(set) var storyboardSpec: String?

    /// The video id whose storyboard spec has been *resolved* — either
    /// successfully fetched, or confirmed absent after a full retry while real
    /// content (not a preroll ad) was playing. Acts as a positive+negative cache
    /// so a re-trigger for the same video is a no-op and storyboard-less videos
    /// don't re-fetch on every playback update.
    private var storyboardFetchVideoId: String?

    /// The video id whose storyboard fetch loop is currently running, to avoid
    /// spawning overlapping loops / repeated WebView evaluations for one video.
    private var storyboardFetchInFlightVideoId: String?

    /// The video whose playback options were last fetched.
    private var playbackOptionsVideoId: String?

    /// Client used by rating actions from the playback controls.
    /// Set once by KasetApp; optional so unit tests don't need it.
    @ObservationIgnored var youtubeClient: (any YouTubeClientProtocol)?

    // MARK: - Hooks

    /// Called right before video playback starts (PlaybackArbiter pauses music).
    var playbackWillStart: (() -> Void)?

    /// Called when the current video finishes (WatchView advances to related).
    var onVideoEnded: ((String?) -> Void)?

    // MARK: - Dependencies

    private let webKitManager: WebKitManager
    let playbackController: any YouTubeWatchPlaybackControlling
    private var usesCookieFreePlaybackDataStore = false
    private let playbackLoadingTimeout: Duration
    private let logger = DiagnosticsLogger.player

    /// Whether a playing video should pop out into the floating window when the
    /// inline watch view disappears (navigate-away). Read live so the user's
    /// setting takes effect mid-session; injected so tests stay deterministic
    /// without touching global `UserDefaults`.
    private let shouldPopOutOnNavigateAway: @MainActor () -> Bool

    /// Whether a playing video should keep playing docked (surface stays inline,
    /// controlled from the bottom player bar) when the inline watch view
    /// disappears, instead of popping out into the floating PiP window. Takes
    /// precedence over `shouldPopOutOnNavigateAway` when both are on. Read live
    /// so the user's setting takes effect mid-session; injected for tests.
    private let shouldKeepPlayingOnNavigateAway: @MainActor () -> Bool

    init(
        webKitManager: WebKitManager = .shared,
        playbackController: (any YouTubeWatchPlaybackControlling)? = nil,
        shouldPopOutOnNavigateAway: @escaping @MainActor () -> Bool = { SettingsManager.shared.popOutVideoOnNavigateAway },
        shouldKeepPlayingOnNavigateAway: @escaping @MainActor () -> Bool = { SettingsManager.shared.keepPlayingVideoOnNavigateAway },
        playbackLoadingTimeout: Duration = .seconds(15)
    ) {
        self.webKitManager = webKitManager
        self.playbackController = playbackController ?? YouTubeWatchWebView.shared
        self.shouldPopOutOnNavigateAway = shouldPopOutOnNavigateAway
        self.shouldKeepPlayingOnNavigateAway = shouldKeepPlayingOnNavigateAway
        self.playbackLoadingTimeout = playbackLoadingTimeout
    }

    // MARK: - Commands

    /// Starts playback of a video, docked inline.
    func play(video: YouTubeVideo, usesCookieFreeDataStore: Bool = false, startAt: Double? = nil) {
        self.beginYouTubePlaybackIntent()
        self.clearAutoplayCountdown()
        self.autoplayRecoveryRequestGeneration &+= 1
        self.shouldRecoverAutoplayTransitionOnResume = false
        let normalizedStartAt = Self.normalizedExplicitStartAt(startAt)
        self.logger.info("YouTubePlayer: play video")
        self.usesCookieFreePlaybackDataStore = usesCookieFreeDataStore
        self.playbackWillStart?()

        if let current = self.currentVideo, current.videoId != video.videoId {
            self.rememberInHistory(current)
        }
        self.upNext = []
        self.currentVideo = video
        self.resetPlaybackOccurrenceState()
        self.desiredPlaybackIntent = .playing
        self.isExplicitPauseIntentActive = false
        self.isAwaitingResumeConfirmation = false
        self.watchActivityGeneration += 1 // a new watch began
        self.currentWatchConcluded = false
        self.isIdentityReloadInFlight = false
        self.resetPerVideoState()
        if let normalizedStartAt {
            self.pendingExplicitStartTarget = ExplicitStartTarget(
                videoId: video.videoId,
                seconds: normalizedStartAt
            )
        }
        self.beginPlaybackLoading()
        self.surfaceLocation = .inline

        // Create the WebView on demand; containers reparent it on appear.
        self.playbackController.prepare(
            webKitManager: self.webKitManager,
            playerService: self,
            usesCookieFreeDataStore: self.usesCookieFreePlaybackDataStore
        )
        if let normalizedStartAt {
            self.playbackController.reloadVideo(videoId: video.videoId, resumeAt: normalizedStartAt)
        } else {
            self.playbackController.loadVideo(videoId: video.videoId)
        }
    }

    nonisolated static func normalizedExplicitStartAt(_ seconds: Double?) -> Double? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }

    /// Re-points the current video under the WebView session's current
    /// (just-switched) delegated identity, preserving playback position.
    ///
    /// Watch history is recorded by the page's own stats pings, which inherit the
    /// identity of the served document. After an account switch the in-flight
    /// page is still the previous identity's document, so a full reload is needed
    /// for continued watching to record to the new account.
    func reloadCurrentVideoForAuthDataStoreChange(usesCookieFreeDataStore: Bool) {
        self.usesCookieFreePlaybackDataStore = usesCookieFreeDataStore
        guard self.currentVideo != nil else { return }
        self.reloadCurrentVideoForIdentitySwitch()
    }

    func reloadCurrentVideoForIdentitySwitch() {
        self.beginYouTubePlaybackIntent()
        guard let currentVideo = self.currentVideo else {
            self.logger.debug("Identity switch: no current video to re-point")
            return
        }
        // Resume at the last real CONTENT position. During an ad, self.progress
        // tracks the ad element's time, so prefer the remembered content progress
        // to avoid resuming the content near 0 after a switch mid-ad.
        let resumeAt = self.interruptionResumeAt(for: currentVideo.videoId)
        let intendsToPlay = self.desiredPlaybackIntent == .playing
        self.logger.info("Identity switch: re-pointing current video under new session identity (resume at \(resumeAt ?? 0)s, intendsToPlay=\(intendsToPlay))")

        if !intendsToPlay {
            // Do not load an autoplaying watch page while the user is paused. The
            // current paused document is inert; reload under the new identity only
            // when the user explicitly resumes.
            self.pendingPausedIdentityReloadVideoId = currentVideo.videoId
            self.pendingPausedIdentityReloadResumeAt = resumeAt
            self.userUpdatedPendingPausedIdentityReloadSeek = false
            return
        }

        self.playbackController.prepare(
            webKitManager: self.webKitManager,
            playerService: self,
            usesCookieFreeDataStore: self.usesCookieFreePlaybackDataStore
        )
        // Defer the seek to load completion: the new <video> element does not
        // exist until the reloaded document finishes, so seeking now would be a
        // no-op against the old/torn-down page.
        self.playbackController.reloadVideo(
            videoId: currentVideo.videoId,
            resumeAt: resumeAt
        )
        self.isIdentityReloadInFlight = true
        self.beginPlaybackLoading()
    }

    // MARK: - Refresh (⌘R) & network auto-retry

    /// User-triggered refresh (⌘R): reloads the current video's playback surface
    /// at its last position, to recover a stuck/black player after a network
    /// interruption without losing the user's place. No-op when nothing is loaded.
    ///
    /// ponytail: a reload autoplays the watch page, so hitting this on a
    /// deliberately-paused video resumes it — acceptable for a "refresh" action,
    /// and the auto-retry path below only calls it when playback should be running.
    func refreshCurrentVideo() {
        guard let currentVideo = self.currentVideo else { return }
        self.logger.info("Manual refresh: reloading current video")
        self.beginYouTubePlaybackIntent()
        let resumeAt = self.interruptionResumeAt(for: currentVideo.videoId)
        self.playbackController.prepare(
            webKitManager: self.webKitManager,
            playerService: self,
            usesCookieFreeDataStore: self.usesCookieFreePlaybackDataStore
        )
        self.playbackController.reloadVideo(videoId: currentVideo.videoId, resumeAt: resumeAt)
        self.isPlaybackLoading = true
    }

    /// Auto-retry when connectivity returns (issue #19): if a video was meant to
    /// be playing but stalled during a network drop — still "loading", or not
    /// playing while the user intends to — reload it. Deliberately-paused
    /// playback is left alone so a network blip never yanks it back to life.
    func handleNetworkRestored() {
        guard self.currentVideo != nil else { return }
        let stalled = self.isPlaybackLoading
            || (self.desiredPlaybackIntent == .playing && !self.isPlaying)
        guard stalled else { return }
        self.logger.info("Network restored: auto-reloading stalled video")
        self.refreshCurrentVideo()
    }

    /// Returns the best native resume target for an interrupted document.
    /// Native seek intent wins until the observer proves it was applied;
    /// otherwise use the last genuine content clock.
    private func interruptionResumeAt(for videoId: String) -> Double? {
        if let pendingUserSeekTarget = self.pendingUserSeekTarget,
           pendingUserSeekTarget.videoId == videoId
        {
            return pendingUserSeekTarget.seconds
        }
        guard !self.currentWatchConcluded else { return nil }
        if let explicitStartTarget = self.explicitStartTarget(for: videoId) {
            return explicitStartTarget
        }
        guard self.lastNonAdContentVideoId == videoId,
              self.lastNonAdContentProgress > 0
        else { return nil }
        return self.lastNonAdContentProgress
    }

    private func explicitStartTarget(for videoId: String) -> Double? {
        guard self.pendingExplicitStartTarget?.videoId == videoId else { return nil }
        return self.pendingExplicitStartTarget?.seconds
    }

    func invalidateExplicitStartTargetForUserSeek() {
        self.pendingExplicitStartTarget = nil
    }

    func recordPendingUserSeek(to seconds: Double) {
        guard let videoId = self.currentVideo?.videoId else { return }
        if self.currentWatchConcluded
            || self.isAutoplayTransitionPending
            || self.shouldRecoverAutoplayTransitionOnResume
        {
            self.autoplayRecoveryRequestGeneration &+= 1
            self.isAutoplayTransitionPending = false
            self.shouldRecoverAutoplayTransitionOnResume = false
        }
        self.pendingUserSeekTarget = PendingUserSeekTarget(
            videoId: videoId,
            seconds: seconds
        )
    }

    func clearPendingUserSeek() {
        self.pendingUserSeekTarget = nil
    }

    func handlePendingSeekExhausted(videoId: String, target: Double) {
        if let explicitStartTarget = self.pendingExplicitStartTarget,
           explicitStartTarget.videoId == videoId,
           abs(explicitStartTarget.seconds - target) < 0.001
        {
            self.pendingExplicitStartTarget = nil
        }
        if let pendingUserSeekTarget = self.pendingUserSeekTarget,
           pendingUserSeekTarget.videoId == videoId,
           abs(pendingUserSeekTarget.seconds - target) < 0.001
        {
            self.pendingUserSeekTarget = nil
        }
        if self.pendingPausedIdentityReloadVideoId == videoId,
           let pendingResumeAt = self.pendingPausedIdentityReloadResumeAt,
           abs(pendingResumeAt - target) < 0.001
        {
            self.pendingPausedIdentityReloadResumeAt = self.interruptionResumeAt(for: videoId)
            self.userUpdatedPendingPausedIdentityReloadSeek = false
        }
    }

    /// Rebuilds a terminated watch-page process while preserving content
    /// position and the user's playing-versus-paused intent.
    func recoverAfterWebContentProcessTermination(resumeAtOverride: Double? = nil) {
        guard let currentVideo = self.currentVideo else { return }

        let hasPendingUserSeek = self.pendingUserSeekTarget?.videoId == currentVideo.videoId
        if self.isAutoplayTransitionPending, !hasPendingUserSeek {
            self.isAutoplayTransitionPending = false
            self.shouldRecoverAutoplayTransitionOnResume = true
            self.desiredPlaybackIntent = .paused
            self.isAwaitingResumeConfirmation = false
            self.autoplayRecoveryRequestGeneration &+= 1
            self.isPlaying = false
            self.isIdentityReloadInFlight = false
            self.finishPlaybackLoading()
            self.hasObservedPausedMedia = true
            return
        }

        let resumeAt = resumeAtOverride ?? self.interruptionResumeAt(for: currentVideo.videoId)

        if self.desiredPlaybackIntent == .paused {
            self.pendingPausedIdentityReloadVideoId = currentVideo.videoId
            self.pendingPausedIdentityReloadResumeAt = resumeAt
            self.userUpdatedPendingPausedIdentityReloadSeek = false
            self.isIdentityReloadInFlight = false
            self.isPlaying = false
            self.finishPlaybackLoading()
            return
        }

        self.playbackController.reloadVideo(videoId: currentVideo.videoId, resumeAt: resumeAt)
        self.isPlaying = false
        self.isIdentityReloadInFlight = true
        self.beginPlaybackLoading()
    }

    /// Leaves a failed watch-page navigation in an explicitly retryable paused
    /// state instead of trusting the outgoing document as the requested video.
    func handleWebNavigationFailure(resumeAtOverride: Double? = nil) {
        self.deferCurrentVideoReload(resumeAtOverride: resumeAtOverride)
    }

    /// Preserves the newly selected native video when its provisional WebView
    /// load is intentionally cancelled (for example, switching sources mid-load).
    /// The outgoing page belongs to the previous video and must not be restored
    /// as authoritative; resume reloads the selected video instead.
    func handleWebNavigationCancellation(resumeAtOverride: Double? = nil) {
        self.deferCurrentVideoReload(resumeAtOverride: resumeAtOverride)
    }

    private func deferCurrentVideoReload(resumeAtOverride: Double? = nil) {
        guard let currentVideo = self.currentVideo else { return }
        self.pendingPausedIdentityReloadVideoId = currentVideo.videoId
        self.pendingPausedIdentityReloadResumeAt = resumeAtOverride
            ?? self.interruptionResumeAt(for: currentVideo.videoId)
        self.userUpdatedPendingPausedIdentityReloadSeek = false
        self.isIdentityReloadInFlight = false
        self.desiredPlaybackIntent = .paused
        // A navigation may have finished before its media became ready, leaving
        // no tracked load for the controller to cancel. Keep late playing
        // samples from re-authorizing that document or consuming the deferred
        // reload before an explicit user resume.
        self.isExplicitPauseIntentActive = true
        self.isAwaitingResumeConfirmation = false
        self.hasObservedPausedMedia = true
        self.isPlaying = false
        self.finishPlaybackLoading()
    }

    /// Toggles play/pause.
    func playPause() {
        self.beginYouTubePlaybackIntent()
        self.performPlayPause()
    }

    func performPlayPause(resumeIssuedAtMilliseconds: Double? = nil) {
        if self.isPlaying
            || self.isAwaitingResumeConfirmation
            || (self.desiredPlaybackIntent == .playing
                && !(self.hasObservedPausedMedia && !self.isPlaying))
        {
            self.performPause()
        } else {
            self.performResume(issuedAtMilliseconds: resumeIssuedAtMilliseconds)
        }
    }

    /// Skips the ad currently playing, resuming the real content at the last
    /// known content position (0 for a pre-roll). Driven by the on-video "Skip
    /// Ad" button.
    func skipAd() {
        self.playbackController.skipAd(resumeAt: self.lastNonAdContentProgress)
    }

    /// Jumps live playback to the live edge (the "LIVE" button).
    func seekToLive() {
        self.playbackController.seekToLive()
    }

    /// Clears the loading spinner when the watch WebView shows a non-playable
    /// page (Google's "/sorry/" CAPTCHA or the consent interstitial), so the
    /// spinner doesn't hide the page the user needs to interact with.
    func clearPlaybackLoadingForInterstitial() {
        self.isPlaybackLoading = false
    }

    /// Resumes playback.
    func resume() {
        self.beginYouTubePlaybackIntent()
        self.performResume()
    }

    func performResume(issuedAtMilliseconds: Double? = nil) {
        self.lastResumeIssuedAtMilliseconds = issuedAtMilliseconds
            ?? Date().timeIntervalSince1970 * 1000
        self.desiredPlaybackIntent = .playing
        self.isExplicitPauseIntentActive = false
        self.isAwaitingResumeConfirmation = true
        self.hasObservedPausedMedia = false
        if self.shouldRecoverAutoplayTransitionOnResume {
            if let nextVideo = self.upNext.first {
                self.advance(to: nextVideo)
            } else {
                // Keep the deferred marker armed while lookup is in flight. A
                // pause may cancel this request generation, but the next resume
                // must retry rather than play the invalidated concluded page.
                self.autoplayRecoveryRequestGeneration &+= 1
                let recoveryGeneration = self.autoplayRecoveryRequestGeneration
                let expectedVideoId = self.currentVideo?.videoId
                Task { @MainActor in
                    await self.recoverAutoplayTransition(
                        expectedVideoId: expectedVideoId,
                        generation: recoveryGeneration
                    )
                }
            }
            return
        }
        self.autoplayRecoveryRequestGeneration &+= 1
        if self.reloadPendingPausedIdentitySwitchForUserResume() {
            return
        }
        self.playbackWillStart?()
        self.playbackController.play()
    }

    @discardableResult
    private func reloadPendingPausedIdentitySwitchForUserResume() -> Bool {
        guard let currentVideo = self.currentVideo,
              self.pendingPausedIdentityReloadVideoId == currentVideo.videoId
        else {
            return false
        }

        let resumeAt = self.pendingPausedIdentityReloadResumeAt
        self.pendingPausedIdentityReloadVideoId = nil
        self.pendingPausedIdentityReloadResumeAt = nil
        self.userUpdatedPendingPausedIdentityReloadSeek = false
        self.playbackWillStart?()
        self.playbackController.prepare(
            webKitManager: self.webKitManager,
            playerService: self,
            usesCookieFreeDataStore: self.usesCookieFreePlaybackDataStore
        )
        self.playbackController.reloadVideo(videoId: currentVideo.videoId, resumeAt: resumeAt)
        self.desiredPlaybackIntent = .playing
        self.isExplicitPauseIntentActive = false
        self.isIdentityReloadInFlight = true
        self.beginPlaybackLoading()
        return true
    }

    /// Pauses playback.
    func pause() {
        self.beginYouTubePlaybackIntent()
        self.performPause()
    }

    func performPause() {
        self.autoplayRecoveryRequestGeneration &+= 1
        self.activateExplicitPauseIntent()
        let didCancelPendingLoad = self.playbackController.cancelPendingLoad()
        if didCancelPendingLoad {
            // Cancellation synchronously re-enters the service's retry path.
            // Reassert the terminal user intent before issuing the raw pause.
            self.activateExplicitPauseIntent()
        }
        self.playbackController.pause()
    }

    func activateExplicitPauseIntent() {
        self.desiredPlaybackIntent = .paused
        self.isExplicitPauseIntentActive = true
        self.isAwaitingResumeConfirmation = false
        self.hasObservedPausedMedia = true
        self.deferInFlightIdentityReloadIfNeeded()
    }

    private func deferInFlightIdentityReloadIfNeeded() {
        if self.isIdentityReloadInFlight, let currentVideo = self.currentVideo {
            self.pendingPausedIdentityReloadVideoId = currentVideo.videoId
            self.pendingPausedIdentityReloadResumeAt = self.interruptionResumeAt(for: currentVideo.videoId)
            self.userUpdatedPendingPausedIdentityReloadSeek = false
            self.pausedIdentityReloadAwaitingFirstUpdate = true
            self.isIdentityReloadInFlight = false
        }
        self.isPlaying = false
        self.finishPlaybackLoading()
    }

    /// Stops playback entirely and releases the surface.
    func stop() {
        self.beginYouTubePlaybackIntent()
        self.clearAutoplayCountdown()
        self.autoplayRecoveryRequestGeneration &+= 1
        self.shouldRecoverAutoplayTransitionOnResume = false
        self.logger.info("YouTubePlayer: stop")
        // Closing/stopping a video that accrued progress changes its resume
        // state in history, so signal the conclusion before clearing — this
        // covers closing the floating window (windowWillClose -> stop) and
        // navigating away with pop-out disabled (inlineSurfaceWillDisappear ->
        // stop) after a partial watch, neither of which emits a skip or finish
        // event. `signalWatchConclusion` de-dupes, so a close right after a
        // natural end (already signalled) does not re-signal the finished video.
        if self.currentVideo != nil, self.progress > 0 {
            if self.signalWatchConclusion() {
                self.watchActivityGeneration += 1
            }
        }
        self.currentVideo = nil
        self.resetPlaybackOccurrenceState()
        self.desiredPlaybackIntent = .paused
        // Teardown invalidates the document generation, but retain the native
        // pause fence until the next play/resume in case a callback was already
        // admitted to main-actor work before teardown began.
        self.isExplicitPauseIntentActive = true
        self.isAwaitingResumeConfirmation = false
        self.isPlaying = false
        self.finishPlaybackLoading()
        self.isIdentityReloadInFlight = false
        self.progress = 0
        self.duration = 0
        self.isShowingAd = false
        self.isAdSkippable = false
        self.isLive = false
        self.isAtLiveEdge = false
        self.resetPerVideoState()
        self.surfaceLocation = .none
        self.activeInlineVideoId = nil
        self.popInRequest = nil
        self.upNext = []
        self.history = []
        self.skipNavigationRequest = nil
        self.pauseInPlaceOnDisappear = false
        self.playbackController.tearDown()
    }

    // MARK: - Surface Placement

    /// Moves the surface to the floating video window.
    func popOutToWindow() {
        guard self.currentVideo != nil else { return }
        self.logger.info("YouTubePlayer: pop out to floating window")
        self.surfaceLocation = .floating
    }

    /// Docks the surface back into the inline watch view.
    func dockInline() {
        guard self.currentVideo != nil else { return }
        self.logger.info("YouTubePlayer: dock inline")
        self.surfaceLocation = .inline
    }

    /// The floating window asked to dock the video back into the app.
    func requestPopIn() {
        guard self.surfaceLocation == .floating, let video = self.currentVideo else { return }
        self.popInRequest = video
    }

    /// Returns the user to the current video's watch view. Works both for a
    /// popped-out (floating) video and for one kept playing docked after a
    /// navigate-away (surface still `.inline`, watch view gone). Routes through
    /// the same pop-in plumbing: KasetApp switches to the video source and
    /// YouTubeContentView opens/adopts the watch view.
    func requestReturnToWatchView() {
        guard let video = self.currentVideo else { return }
        self.popInRequest = video
    }

    /// Whether the current video is playing docked with no watch view on screen
    /// (the "keep playing on navigate-away" case), so UI can offer a way back.
    var isPlayingDockedWithoutWatchView: Bool {
        self.currentVideo != nil
            && self.surfaceLocation == .inline
            && self.activeInlineVideoId == nil
    }

    /// Marks the pop-in request as handled.
    func consumePopInRequest() {
        self.popInRequest = nil
    }

    // MARK: - Skipping

    /// Supplies up-next candidates (the watch page's related list).
    func setUpNext(_ videos: [YouTubeVideo]) {
        let currentId = self.currentVideo?.videoId
        self.upNext = videos.filter { $0.videoId != currentId && !$0.isShort }
    }

    /// Supplies chapter navigation markers for the current video.
    func setChapters(_ chapters: [YouTubeChapter]) {
        guard let currentId = self.currentVideo?.videoId else {
            self.chapters = []
            return
        }
        self.chapters = chapters.filter { $0.videoId == nil || $0.videoId == currentId }
    }

    /// Supplies "most replayed" heatmap samples for the current video.
    func setHeatmap(_ heatmap: [YouTubeHeatmapMarker]) {
        guard self.currentVideo != nil else {
            self.heatmap = []
            return
        }
        self.heatmap = heatmap
    }

    /// Skips to the next video (first up-next candidate; fetched lazily
    /// when none are known, e.g. when playing in the floating window).
    func skipForward() async {
        let playbackIntentGeneration = self.beginYouTubePlaybackIntent()
        await self.skipForward(ownedBy: playbackIntentGeneration)
    }

    func skipForward(ownedBy playbackIntentGeneration: UInt64) async {
        guard let current = self.currentVideo else { return }

        var target = self.upNext.first
        if target == nil, let client = self.youtubeClient {
            target = await (try? client.getWatchNext(videoId: current.videoId, playlistId: nil))?
                .related.first { !$0.isShort }
            guard self.youtubePlaybackIntentGeneration == playbackIntentGeneration,
                  self.currentVideo?.videoId == current.videoId
            else { return }
        }
        guard let next = target else { return }
        // `advance` deliberately preserves the already-admitted intent generation and
        // timestamp; it must not restamp an async remote-next completion.
        self.advance(to: next)
    }

    /// Skips back to the previously played video, or restarts the current
    /// one when there is no history.
    func skipBackward() {
        self.beginYouTubePlaybackIntent()
        self.skipBackwardWithoutBeginningIntent()
    }

    func skipBackwardWithoutBeginningIntent() {
        if let previous = self.history.popLast() {
            self.advance(to: previous, recordingHistory: false)
        } else {
            self.seek(to: 0)
        }
    }

    /// Marks the skip navigation request as handled.
    func consumeSkipNavigationRequest() {
        self.skipNavigationRequest = nil
    }

    private func advance(to video: YouTubeVideo, recordingHistory: Bool = true) {
        self.clearAutoplayCountdown()
        self.autoplayRecoveryRequestGeneration &+= 1
        self.shouldRecoverAutoplayTransitionOnResume = false
        self.logger.info("YouTubePlayer: advancing to another video")
        if recordingHistory, let current = self.currentVideo {
            self.rememberInHistory(current)
        }
        self.upNext.removeAll { $0.videoId == video.videoId }

        self.playbackWillStart?()
        self.currentVideo = video
        self.resetPlaybackOccurrenceState()
        self.desiredPlaybackIntent = .playing
        self.isExplicitPauseIntentActive = false
        // A skip concludes the prior watch (deduped) and begins a new one.
        self.signalWatchConclusion()
        self.watchActivityGeneration += 1
        self.currentWatchConcluded = false
        self.isIdentityReloadInFlight = false
        self.resetPerVideoState()
        self.beginPlaybackLoading()
        self.playbackController.prepare(
            webKitManager: self.webKitManager,
            playerService: self,
            usesCookieFreeDataStore: self.usesCookieFreePlaybackDataStore
        )
        self.playbackController.loadVideo(videoId: video.videoId)

        // Keep the surface where it is; when docked inline the content view
        // opens the new video's watch view.
        if self.surfaceLocation == .inline {
            self.skipNavigationRequest = video
        }
    }

    private func recoverAutoplayTransition(
        expectedVideoId: String?,
        generation: UInt64
    ) async {
        guard let expectedVideoId,
              let client = self.youtubeClient
        else {
            self.finishFailedAutoplayRecovery(generation: generation)
            return
        }
        let nextVideo = await (try? client.getWatchNext(videoId: expectedVideoId, playlistId: nil))?
            .related.first { !$0.isShort }
        guard generation == self.autoplayRecoveryRequestGeneration,
              self.currentVideo?.videoId == expectedVideoId,
              self.desiredPlaybackIntent == .playing
        else { return }
        guard let nextVideo else {
            self.finishFailedAutoplayRecovery(generation: generation)
            return
        }
        self.advance(to: nextVideo)
    }

    private func finishFailedAutoplayRecovery(generation: UInt64) {
        guard generation == self.autoplayRecoveryRequestGeneration else { return }
        self.shouldRecoverAutoplayTransitionOnResume = true
        self.desiredPlaybackIntent = .paused
        self.isAwaitingResumeConfirmation = false
        self.hasObservedPausedMedia = true
    }

    private func rememberInHistory(_ video: YouTubeVideo) {
        self.history.append(video)
        if self.history.count > 50 {
            self.history.removeFirst()
        }
    }

    /// Clears state that is scoped to a single video.
    private func resetPerVideoState(preservingPendingSponsorBlockState: Bool = false) {
        self.progress = 0
        self.duration = 0
        self.currentRating = .none
        self.isInWatchLater = false
        self.chapters = []
        self.heatmap = []
        self.captionTracks = []
        self.activeCaptionLanguageCode = nil
        self.audioTracks = []
        self.activeAudioTrackId = nil
        self.qualityLevels = []
        self.currentQuality = nil
        self.userPinnedQuality = nil
        self.currentMediaIsLive = false
        self.storyboardSpec = nil
        self.sponsorSegments = []
        self.dismissSponsorBlockSkipNotice()
        if !preservingPendingSponsorBlockState {
            self.pendingSponsorSegments = nil
            self.pendingSponsorSkip = nil
        }
        self.rydDislikes = nil
        self.rydLikes = nil
        self.rydFetchVideoId = nil
        // DeArrow cache is shared — no per-video teardown needed
        self.storyboardFetchVideoId = nil
        self.storyboardFetchInFlightVideoId = nil
        self.playbackOptionsVideoId = nil
        // A genuinely new video starts under the user's own intent; never inherit
        // a deferred identity-reload latch from a prior video.
        self.pendingPausedIdentityReloadVideoId = nil
        self.pendingPausedIdentityReloadResumeAt = nil
        self.userUpdatedPendingPausedIdentityReloadSeek = false
        self.pausedIdentityReloadAwaitingFirstUpdate = false
        self.pendingExplicitStartTarget = nil
        self.pendingUserSeekTarget = nil
        self.isAutoplayTransitionPending = false
        self.shouldRecoverAutoplayTransitionOnResume = false
        self.lastNonAdContentProgress = 0
        self.lastNonAdContentVideoId = nil
        self.hasObservedPausedMedia = false
        self.isAwaitingResumeConfirmation = false
        self.clearRelativeSeekCoalescingTarget()
    }

    // MARK: - Watch Later

    /// Adds/removes the current video from Watch Later (optimistic with rollback).
    func toggleWatchLater() async {
        guard let video = self.currentVideo, let client = self.youtubeClient else { return }
        let wasInWatchLater = self.isInWatchLater
        self.isInWatchLater = !wasInWatchLater
        do {
            if wasInWatchLater {
                try await client.removeFromWatchLater(videoId: video.videoId)
            } else {
                try await client.addToWatchLater(videoId: video.videoId)
            }
            HapticService.toggle()
        } catch {
            self.logger.error("Failed to edit Watch Later: \(error.localizedDescription)")
            self.isInWatchLater = wasInWatchLater
        }
    }

    // MARK: - Captions & Quality

    /// Loads the caption tracks and quality levels the watch page offers.
    /// Retries briefly — the captions module often isn't ready the moment
    /// playback starts — and reads the player's actual caption state
    /// (YouTube persists captions-on across sessions).
    func refreshPlaybackOptions() async {
        let videoId = self.currentVideo?.videoId
        for attempt in 0 ..< 3 {
            let tracks = await self.playbackController.availableCaptionTracks()
            guard self.currentVideo?.videoId == videoId else { return }

            self.captionTracks = tracks
            let levels = await self.playbackController.availableQualityLevels()
            // The player accepts "auto" even when it does not advertise it, and
            // the menu needs that row to represent an unpinned quality.
            self.qualityLevels = levels.isEmpty || levels.contains("auto")
                ? levels
                : levels + ["auto"]
            self.currentQuality = await self.playbackController.currentQualityLevel()
            self.activeCaptionLanguageCode = await self.playbackController.currentCaptionLanguageCode()
            self.audioTracks = await self.playbackController.availableAudioTracks()
            self.activeAudioTrackId = await self.playbackController.currentAudioTrackId()

            if !tracks.isEmpty || attempt == 2 {
                return
            }
            try? await Task.sleep(for: .milliseconds(1500))
        }
    }

    /// Fetches the storyboard spec for the ambient backdrop, keyed to its video
    /// so a previous video's spec never leaks forward. Kept separate from
    /// `refreshPlaybackOptions` so this cosmetic-only data never delays caption
    /// or quality loading. Retries briefly since the player response, like the
    /// captions module, isn't ready the instant playback starts.
    func refreshStoryboardSpec() async {
        let videoId = self.currentVideo?.videoId
        // Already resolved this exact video (got a spec, or confirmed it has
        // none after a full retry) — nothing to do. The trigger only calls this
        // for real content, never during a preroll ad, so a resolved `nil` here
        // is a genuine "no storyboard" and is safe to cache as a negative result
        // instead of re-fetching on every 1 Hz playback update.
        if self.storyboardFetchVideoId == videoId {
            return
        }
        if self.storyboardFetchInFlightVideoId == videoId {
            return
        }
        self.storyboardFetchInFlightVideoId = videoId
        defer {
            if self.storyboardFetchInFlightVideoId == videoId {
                self.storyboardFetchInFlightVideoId = nil
            }
        }
        // Drop any spec from a previous video before awaiting the refetch.
        self.storyboardSpec = nil
        self.storyboardFetchVideoId = nil

        for attempt in 0 ..< 3 {
            let spec = await self.playbackController.storyboardSpec(expectedVideoId: videoId)
            guard self.currentVideo?.videoId == videoId else { return }
            if let spec {
                self.storyboardSpec = spec
                self.storyboardFetchVideoId = videoId
                return
            }
            if attempt == 2 {
                // Retries exhausted on real content: cache the negative result
                // so we don't loop forever on a storyboard-less video.
                self.storyboardFetchVideoId = videoId
                return
            }
            try? await Task.sleep(for: .milliseconds(1500))
        }
    }

    /// Selects a caption track (nil turns captions off).
    func selectCaptionTrack(languageCode: String?) {
        self.activeCaptionLanguageCode = languageCode
        self.playbackController.setCaptionTrack(languageCode: languageCode)
        HapticService.toggle()
    }

    /// Selects an alternate audio track (dubbed language) by id.
    func selectAudioTrack(id: String) {
        self.activeAudioTrackId = id
        self.playbackController.setAudioTrack(id: id)
        HapticService.toggle()
    }

    /// Selects a playback quality level.
    func selectQuality(_ level: String) {
        self.currentQuality = level
        // "auto" clears the pin (back to Auto); any real level pins it.
        self.userPinnedQuality = (level == "auto") ? nil : level
        self.playbackController.setQualityLevel(level)
        HapticService.toggle()
    }

    // MARK: - AirPlay

    /// Shows the system AirPlay picker for the video element.
    func showAirPlayPicker() {
        self.playbackController.showAirPlayPicker()
    }

    // MARK: - Rating

    /// Toggles a like on the current video (optimistic with rollback).
    func toggleLike() async {
        await self.setRating(self.currentRating == .like ? .none : .like)
    }

    /// Toggles a dislike on the current video (optimistic with rollback).
    func toggleDislike() async {
        await self.setRating(self.currentRating == .dislike ? .none : .dislike)
    }

    private func setRating(_ newRating: YouTubeRating) async {
        guard let video = self.currentVideo, let client = self.youtubeClient else { return }
        let previous = self.currentRating
        self.currentRating = newRating
        do {
            try await client.rateVideo(videoId: video.videoId, rating: newRating)
            HapticService.toggle()
        } catch {
            self.logger.error("Failed to rate video: \(error.localizedDescription)")
            self.currentRating = previous
        }
    }

    /// Set by the source toggle right before switching away from the video
    /// source: the inline surface pauses in place (no pop-out window) and
    /// the restored watch view re-adopts it when the user comes back.
    private var pauseInPlaceOnDisappear = false
}

extension YouTubePlayerService {
    private func beginPlaybackLoading() {
        self.playbackLoadingTimeoutTask?.cancel()
        self.playbackLoadingGeneration &+= 1
        let loadingGeneration = self.playbackLoadingGeneration
        self.isPlaybackLoading = true

        let timeout = self.playbackLoadingTimeout
        let videoId = self.currentVideo?.videoId
        self.playbackLoadingTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.playbackLoadingGeneration == loadingGeneration,
                  self.isPlaybackLoading,
                  self.currentVideo?.videoId == videoId
            else { return }
            if !self.playbackController.cancelPendingLoad() {
                self.deferCurrentVideoReload()
            }
        }
    }

    private func finishPlaybackLoading() {
        self.playbackLoadingGeneration &+= 1
        self.isPlaybackLoading = false
        self.playbackLoadingTimeoutTask?.cancel()
        self.playbackLoadingTimeoutTask = nil
    }

    /// Prepares the inline surface for a switch to the music source:
    /// pause in place, keep everything loaded for restore.
    func prepareForSourceSwitch() {
        guard self.surfaceLocation == .inline, self.currentVideo != nil else { return }
        if self.desiredPlaybackIntent == .playing {
            self.pause()
        }
        self.pauseInPlaceOnDisappear = true
    }

    /// A WatchView for `videoId` is disappearing. If it owns the inline
    /// surface, hand off: keep playing in the floating window, stop if
    /// paused — or, during a source switch, stay paused in place.
    func inlineSurfaceWillDisappear(videoId: String) {
        guard self.activeInlineVideoId == videoId else { return }
        self.activeInlineVideoId = nil

        guard self.currentVideo?.videoId == videoId, self.surfaceLocation == .inline else {
            self.pauseInPlaceOnDisappear = false
            return
        }

        if self.pauseInPlaceOnDisappear {
            self.pauseInPlaceOnDisappear = false
            // Surface stays .inline and paused; returning to the video
            // source re-adopts it on the same watch view.
            return
        }

        if self.isPlaying, self.shouldKeepPlayingOnNavigateAway() {
            // "No PiP" return option: keep the video playing docked. The surface
            // stays .inline (so no floating window opens); the webview detaches
            // from the view hierarchy and keeps playing (audio continues, like
            // backgrounded music). The bottom player bar stays visible and the
            // user returns to the video from there.
            self.detachInlineSurfaceKeepingPlayback()
        } else if self.isPlaying, self.shouldPopOutOnNavigateAway() {
            self.popOutToWindow()
        } else {
            // Playing with both options off, or paused: stop instead of
            // leaving a detached surface.
            self.stop()
        }
    }

    /// Keeps the current video playing while its inline watch view goes away,
    /// without popping out to the floating window. The surface stays `.inline`
    /// so the docked player bar remains the control surface and returning to the
    /// video re-adopts the same inline surface (via a pop-in request).
    private func detachInlineSurfaceKeepingPlayback() {
        self.logger.info("YouTubePlayer: keep playing docked on navigate-away (no PiP)")
        // Nothing else to change: surface remains .inline and playback continues.
        // `activeInlineVideoId` was already cleared by the caller, so the next
        // watch view for this video will re-adopt the surface on appear.
    }

    // MARK: - Bridge Callbacks

    /// A `STATE_UPDATE` payload from the watch page observer script.
    struct PlaybackUpdate {
        let isPlaying: Bool
        let progress: Double
        let duration: Double
        var hasReadyMedia = false
        var hasMediaError = false
        var videoId: String?
        var boundVideoId: String?
        var title: String?
        var isAd = false
        var isAdSkippable = false
        var isLive = false
        var isAtLiveEdge = false
        var didApplyPendingSeek = false
        var didFailPendingSeek = false
        var pendingSeekTarget: Double?
        var pendingSeekVideoId: String?
        var pendingSeekAttempt: UInt64?
        var nativePausePending = false
        var eventIssuedAtMilliseconds: Double?
        var playbackOccurrence: YouTubePlaybackOccurrence?
    }

    /// Applies a `STATE_UPDATE` from the watch page observer script.
    ///
    /// Observable properties are only assigned when the value actually changed:
    /// `@Observable` notifies observers on every write regardless of equality,
    /// so unconditional assignment here would invalidate every view reading
    /// `isPlaying`/`duration`/`isShowingAd` on each 1 Hz bridge update even
    /// though only `progress` moved.
    func updatePlaybackState(_ update: PlaybackUpdate) {
        self.recordPostConclusionAutoplayTransitionIfNeeded(update)
        guard self.acceptsPlaybackOccurrence(update.playbackOccurrence) else { return }
        let reconciledPlayingState = self.reconciledPlayingState(for: update)
        guard self.currentVideo != nil else {
            if reconciledPlayingState.wasSuppressed {
                self.playbackController.pause()
            }
            return
        }
        self.bindPlaybackOccurrence(update.playbackOccurrence)
        let effectiveIsPlaying = reconciledPlayingState.isPlaying
        let shouldPreserveTerminalIntent = self.currentWatchConcluded
            && self.desiredPlaybackIntent == .paused
            && !update.hasReadyMedia
        self.reconcileObservedPauseIntent(update)
        self.reconcileDesiredPlaybackIntent(
            for: update,
            effectiveIsPlaying: effectiveIsPlaying,
            shouldPreserveTerminalIntent: shouldPreserveTerminalIntent
        )

        let completedIdentityReload = self.isIdentityReloadInFlight
            || self.pausedIdentityReloadAwaitingFirstUpdate
        guard !self.reconcilePendingPausedIdentityReload(
            for: update,
            effectiveIsPlaying: effectiveIsPlaying,
            completedIdentityReload: completedIdentityReload
        ) else { return }
        self.completeIdentityReloadIfNeeded(completedIdentityReload)

        // A bridge update from the newly accepted document proves a successful
        // reload. Later pause/resume must control that document directly rather
        // than scheduling another identity reload.
        self.isIdentityReloadInFlight = false
        self.acknowledgeExplicitStartTarget(with: update)
        self.acknowledgePendingUserSeek(with: update)
        self.applyPlaybackSnapshot(update, effectiveIsPlaying: effectiveIsPlaying)
        self.reopenConcludedWatchIfNeeded(update, effectiveIsPlaying: effectiveIsPlaying)
        self.refreshPlaybackMetadataIfNeeded(update, effectiveIsPlaying: effectiveIsPlaying)
        self.followPageDriftIfNeeded(update)
        self.finishPlaybackLoadingIfReady(update)
        self.deferMediaErrorIfNeeded(update)
        self.completeAutoplayTransitionIfNeeded(update)
        self.recordReadyContentProgressIfPossible(update)

        if reconciledPlayingState.wasSuppressed {
            self.playbackController.pause()
        }
    }

    /// A concluded media occurrence can keep emitting loading/ad snapshots while
    /// YouTube prepares autoplay. Record only the recovery marker before stale
    /// occurrence filtering; the rejected snapshot must not mutate normal state.
    func recordPostConclusionAutoplayTransitionIfNeeded(_ update: PlaybackUpdate) {
        guard self.currentVideo != nil,
              self.currentWatchConcluded,
              self.desiredPlaybackIntent == .paused,
              self.pendingUserSeekTarget == nil,
              update.isAd || !update.hasReadyMedia
        else { return }
        self.isAutoplayTransitionPending = true
    }

    private func reconcileDesiredPlaybackIntent(
        for update: PlaybackUpdate,
        effectiveIsPlaying: Bool,
        shouldPreserveTerminalIntent: Bool
    ) {
        if effectiveIsPlaying {
            // Accepted playback (including YouTube autoplay/SPA drift) becomes
            // the authoritative requested-play intent for future recovery.
            let isCurrentResumeSample = if self.isAwaitingResumeConfirmation,
                                           let lastResumeIssuedAtMilliseconds,
                                           let eventIssuedAtMilliseconds = update.eventIssuedAtMilliseconds
            {
                eventIssuedAtMilliseconds >= lastResumeIssuedAtMilliseconds
            } else {
                true
            }
            if !shouldPreserveTerminalIntent,
               !update.nativePausePending,
               isCurrentResumeSample
            {
                self.desiredPlaybackIntent = .playing
                self.isAwaitingResumeConfirmation = false
            }
            self.hasObservedPausedMedia = false
        } else if update.hasReadyMedia {
            self.hasObservedPausedMedia = true
        }
    }

    @discardableResult
    private func reconcilePendingPausedIdentityReload(
        for update: PlaybackUpdate,
        effectiveIsPlaying: Bool,
        completedIdentityReload: Bool
    ) -> Bool {
        guard let pendingId = self.pendingPausedIdentityReloadVideoId,
              pendingId == (update.videoId ?? self.currentVideo?.videoId)
        else { return false }

        if effectiveIsPlaying, !completedIdentityReload {
            if self.pendingPausedIdentityReloadResumeAt == nil {
                self.pendingPausedIdentityReloadResumeAt =
                    self.explicitStartTarget(for: pendingId)
                        ?? self.deferredIdentityReloadResumeProgress(for: update)
            }
            _ = self.reloadPendingPausedIdentitySwitchForUserResume()
            return true
        }
        if !effectiveIsPlaying, !self.userUpdatedPendingPausedIdentityReloadSeek {
            self.pendingPausedIdentityReloadResumeAt =
                self.explicitStartTarget(for: pendingId)
                    ?? self.deferredIdentityReloadResumeProgress(for: update)
        }
        return false
    }

    private func completeIdentityReloadIfNeeded(_ completedIdentityReload: Bool) {
        guard completedIdentityReload else { return }
        self.pendingPausedIdentityReloadVideoId = nil
        self.pendingPausedIdentityReloadResumeAt = nil
        self.userUpdatedPendingPausedIdentityReloadSeek = false
        self.pausedIdentityReloadAwaitingFirstUpdate = false
    }

    private func applyPlaybackSnapshot(
        _ update: PlaybackUpdate,
        effectiveIsPlaying: Bool
    ) {
        // YouTube can start the next video on its own (SPA navigation);
        // make sure music yields whenever video audio actually starts.
        if effectiveIsPlaying, !self.isPlaying {
            self.playbackWillStart?()
        }

        // Assign observable properties only when they actually change:
        // `@Observable` notifies on every write regardless of equality, so
        // unconditional assignment would invalidate every view reading
        // isPlaying/duration/isShowingAd on each 1 Hz bridge update.
        // Use #374's reconciled `effectiveIsPlaying` (not the raw
        // `update.isPlaying`) so suppressed/pending states are honored.
        if self.isPlaying != effectiveIsPlaying {
            self.isPlaying = effectiveIsPlaying
        }
        if self.progress != update.progress {
            self.progress = update.progress
        }
        if self.duration != update.duration {
            self.duration = update.duration
        }
        if self.isShowingAd != update.isAd {
            self.isShowingAd = update.isAd
        }
        let skippable = update.isAd && update.isAdSkippable
        if self.isAdSkippable != skippable {
            self.isAdSkippable = skippable
        }
        if self.isLive != update.isLive {
            self.isLive = update.isLive
        }
        if self.isAtLiveEdge != update.isAtLiveEdge {
            self.isAtLiveEdge = update.isAtLiveEdge
        }
        // Runtime liveness from the bound media element (URL launches, SPA drift
        // whose feed model lacked liveness). The loading spinner is cleared by
        // `finishPlaybackLoadingIfReady` and media errors handled by
        // `deferMediaErrorIfNeeded` from the STATE_UPDATE handler (#408).
        if !update.isAd,
           update.hasReadyMedia,
           let metadataVideoId = update.videoId,
           update.boundVideoId == metadataVideoId
        {
            let resolvedIsLive = update.isLive || self.currentVideo?.isLive == true
            self.currentMediaIsLive = resolvedIsLive
            if resolvedIsLive {
                self.updateCurrentVideoLiveness(true, videoId: metadataVideoId)
            }
        }
    }

    private func finishPlaybackLoadingIfReady(_ update: PlaybackUpdate) {
        guard self.readyMediaBelongsToCurrentPlayback(update)
            || self.metadataReadyForCurrentPlayback(update)
        else { return }
        self.finishPlaybackLoading()
    }

    /// The fork's original loading-finish signal: a known duration means metadata
    /// loaded and a frame is imminent. Kept alongside #408's stricter ready-media
    /// check so surfaces that gate on `isPlaybackLoading` — notably the Shorts
    /// thumbnail cover — still clear when a video reports its duration before the
    /// bridge flags ready media. Ads and media-error frames are excluded so the
    /// ad surface and error recovery are unaffected.
    private func metadataReadyForCurrentPlayback(_ update: PlaybackUpdate) -> Bool {
        guard update.duration > 0, !update.hasMediaError, !update.isAd,
              let currentVideoId = self.currentVideo?.videoId
        else { return false }
        // The first frames may not have bound the media id yet; accept a matching
        // or not-yet-known id, but never another video's snapshot.
        if let boundVideoId = update.boundVideoId, boundVideoId != currentVideoId {
            return false
        }
        return update.videoId == nil || update.videoId == currentVideoId
    }

    private func readyMediaBelongsToCurrentPlayback(_ update: PlaybackUpdate) -> Bool {
        guard update.hasReadyMedia, !update.hasMediaError else { return false }
        // Preroll and midroll ads use the selected video's media element and are
        // sufficient to replace the initial black loading surface, but a queued
        // ad snapshot from outgoing media must not finish a newer video's load.
        if update.isAd {
            return update.boundVideoId == self.currentVideo?.videoId
        }
        guard let currentVideoId = self.currentVideo?.videoId else { return false }
        return update.videoId == currentVideoId && update.boundVideoId == currentVideoId
    }

    private func deferMediaErrorIfNeeded(_ update: PlaybackUpdate) {
        guard self.mediaErrorBelongsToCurrentContent(update) else { return }
        self.deferCurrentVideoReload()
    }

    private func mediaErrorBelongsToCurrentContent(_ update: PlaybackUpdate) -> Bool {
        guard update.hasMediaError,
              !update.isAd,
              let currentVideoId = self.currentVideo?.videoId
        else { return false }

        if let boundVideoId = update.boundVideoId,
           boundVideoId != currentVideoId
        {
            return false
        }
        return update.videoId == nil || update.videoId == currentVideoId
    }

    private func reopenConcludedWatchIfNeeded(
        _ update: PlaybackUpdate,
        effectiveIsPlaying: Bool
    ) {
        // A concluded video that is playing again (replayed via the player bar or
        // a seek back after it finished) begins a fresh watch — clear the
        // conclusion flag so its later stop/finish signals the new partial
        // rewatch instead of being deduped. Only when it's the same current video
        // still playing real content (drift to a different id is handled below
        // and starts its own unconcluded watch).
        if self.currentWatchConcluded,
           effectiveIsPlaying,
           !update.isAd,
           let videoId = update.videoId,
           videoId == self.currentVideo?.videoId
        {
            self.currentWatchConcluded = false
        }
    }

    private func completeAutoplayTransitionIfNeeded(_ update: PlaybackUpdate) {
        guard self.isAutoplayTransitionPending,
              !self.currentWatchConcluded,
              !update.isAd,
              update.hasReadyMedia,
              let boundVideoId = update.boundVideoId,
              boundVideoId == self.currentVideo?.videoId
        else { return }
        self.isAutoplayTransitionPending = false
    }

    private func refreshPlaybackMetadataIfNeeded(
        _ update: PlaybackUpdate,
        effectiveIsPlaying: Bool
    ) {
        // Fetch captions/quality options once per video, after playback starts
        // (the player APIs aren't ready before that).
        if effectiveIsPlaying,
           let videoId = self.currentVideo?.videoId,
           self.playbackOptionsVideoId != videoId
        {
            self.playbackOptionsVideoId = videoId
            Task {
                await self.refreshPlaybackOptions()
            }
        }

        // Fetch Return YouTube Dislikes once per video
        if update.isPlaying,
           let videoId = self.currentVideo?.videoId,
           self.rydFetchVideoId == nil
        {
            Task {
                await self.fetchReturnYouTubeDislikes(videoId: videoId)
            }
        }

        // Trigger DeArrow fetch via shared cache (non-blocking)
        if let videoId = self.currentVideo?.videoId {
            DearrowCache.shared.fetchOneIfNeeded(videoId: videoId)
        }

        // The storyboard spec drives the ambient backdrop's color and the
        // on-video scrub hover preview, so fetch it when either feature is on
        // and real content (not a preroll ad) is playing. Not gated on the
        // one-shot playback-options branch above, so it also fires when the
        // user enables a feature mid-playback or when content starts after an
        // ad. `refreshStoryboardSpec` is self-guarding, so calling it on each
        // qualifying update is cheap.
        if update.isPlaying,
           !update.isAd,
           self.currentVideo != nil,
           SettingsManager.shared.ambientBackdropEnabled
           || SettingsManager.shared.controlsOnVideoEnabled
        {
            Task {
                await self.refreshStoryboardSpec()
            }
        }
    }

    private func followPageDriftIfNeeded(_ update: PlaybackUpdate) {
        // Track SPA drift: if the page moved to a different video, follow it
        // so the controls stay truthful.
        guard !update.isAd,
              let videoId = update.videoId,
              let current = self.currentVideo,
              videoId != current.videoId,
              !self.isAutoplayTransitionPending
              || (update.hasReadyMedia && update.boundVideoId == videoId)
        else { return }

        self.beginYouTubePlaybackIntent(
            issuedAtMilliseconds: update.eventIssuedAtMilliseconds
        )
        self.logger.info("YouTubePlayer: page drifted to a different video, following")
        let shouldRepointDriftedVideo = self.pendingPausedIdentityReloadVideoId != nil
        let driftedContentProgress: Double? = if !update.isAd,
                                                 update.hasReadyMedia,
                                                 update.boundVideoId == videoId
        {
            update.progress
        } else {
            nil
        }
        // Preserve any SponsorBlock segments already fetched for the drifted-to
        // video (fork feature): reset per-video state without clobbering pending
        // SponsorBlock state, then reapply it for the new video id.
        let driftedIsLive = update.hasReadyMedia
            && update.boundVideoId == videoId
            && update.isLive
        self.resetPerVideoState(preservingPendingSponsorBlockState: true)
        self.currentMediaIsLive = driftedIsLive
        self.currentVideo = YouTubeVideo(
            videoId: videoId,
            title: update.title ?? current.title,
            channelName: current.channelName,
            channelId: current.channelId,
            isLive: driftedIsLive
        )
        self.applyPendingSponsorBlockState(for: videoId)
        let readyMediaBelongsToDriftedVideo = update.hasReadyMedia
            && !update.hasMediaError
            && update.boundVideoId == videoId
        if !readyMediaBelongsToDriftedVideo {
            // The previous timeout was keyed to the outgoing video. Start a
            // fresh bound for the drifted document so an empty replacement
            // cannot strand loading indefinitely.
            self.beginPlaybackLoading()
        }
        if let driftedContentProgress {
            self.lastNonAdContentProgress = driftedContentProgress
            self.lastNonAdContentVideoId = videoId
        }
        // The page autoplayed/navigated to a new video (e.g. in the floating
        // window) — the prior video concluded and a new watch began. Signal
        // the conclusion (unless it already finished, to avoid double-bumping
        // a natural end that auto-advances), then mark the new video as a
        // fresh, unconcluded watch.
        self.signalWatchConclusion()
        self.watchActivityGeneration += 1
        self.currentWatchConcluded = false
        YouTubeWatchWebView.shared.currentVideoId = videoId
        if shouldRepointDriftedVideo {
            self.reloadCurrentVideoForIdentitySwitch()
        }
    }

    private func recordReadyContentProgressIfPossible(_ update: PlaybackUpdate) {
        // Record only a ready physical-media clock owned by the now-current
        // video. Page metadata can lead the actual element during SPA drift.
        if !update.isAd,
           update.hasReadyMedia,
           let boundVideoId = update.boundVideoId,
           boundVideoId == self.currentVideo?.videoId
        {
            self.lastNonAdContentProgress = update.progress
            self.lastNonAdContentVideoId = boundVideoId
        }
    }

    private func updateCurrentVideoLiveness(_ isLive: Bool, videoId: String?) {
        guard let videoId,
              let current = self.currentVideo,
              current.videoId == videoId,
              current.isLive != isLive
        else { return }
        self.currentVideo = YouTubeVideo(
            videoId: current.videoId,
            title: current.title,
            channelName: current.channelName,
            channelId: current.channelId,
            lengthText: current.lengthText,
            viewCountText: current.viewCountText,
            publishedText: current.publishedText,
            thumbnailURL: current.thumbnailURL,
            isLive: isLive,
            isShort: current.isShort,
            watchedPercent: current.watchedPercent
        )
    }

    private func reconciledPlayingState(for update: PlaybackUpdate) -> (
        isPlaying: Bool,
        wasSuppressed: Bool
    ) {
        // Kaset's native controls own explicit pause/resume intent. Web playback
        // samples may acknowledge the pause, but cannot revoke it; only a native
        // resume/new-watch action clears `isExplicitPauseIntentActive`.
        let isSuppressed = update.isPlaying
            && self.isExplicitPauseIntentActive
        return (update.isPlaying && !isSuppressed, isSuppressed)
    }

    private func reconcileObservedPauseIntent(_ update: PlaybackUpdate) {
        guard !update.isPlaying,
              !self.isExplicitPauseIntentActive,
              !self.isAwaitingResumeConfirmation,
              !self.isPlaybackLoading,
              update.hasReadyMedia,
              !update.isAd,
              self.isPlaying
        else { return }
        self.desiredPlaybackIntent = .paused
    }

    private func deferredIdentityReloadResumeProgress(for update: PlaybackUpdate) -> Double? {
        let currentVideoId = self.currentVideo?.videoId
        if !update.isAd,
           update.hasReadyMedia,
           update.boundVideoId == currentVideoId,
           update.progress > 0
        {
            return update.progress
        }
        guard self.lastNonAdContentVideoId == currentVideoId,
              self.lastNonAdContentProgress > 0
        else { return nil }
        return self.lastNonAdContentProgress
    }

    private func acknowledgeExplicitStartTarget(with update: PlaybackUpdate) {
        guard !update.isAd,
              let target = self.pendingExplicitStartTarget,
              (update.pendingSeekVideoId ?? update.videoId) == target.videoId
        else { return }
        guard update.didApplyPendingSeek else { return }
        self.pendingExplicitStartTarget = nil
    }

    private func acknowledgePendingUserSeek(with update: PlaybackUpdate) {
        guard update.didApplyPendingSeek,
              let pendingUserSeekTarget = self.pendingUserSeekTarget,
              update.pendingSeekVideoId == pendingUserSeekTarget.videoId,
              let appliedTarget = update.pendingSeekTarget,
              abs(appliedTarget - pendingUserSeekTarget.seconds) < 0.001
        else { return }
        self.pendingUserSeekTarget = nil
    }

    /// Handles natural video completion.
    @discardableResult
    func handleVideoEnded(
        videoId: String?,
        playbackOccurrence: YouTubePlaybackOccurrence? = nil,
        eventIssuedAtMilliseconds: Double? = nil,
        isNativeTerminal: Bool = false
    ) -> Bool {
        self.logger.info("YouTubePlayer: video ended")
        // Ignore an ended event that is not for the CURRENT content watch:
        //   - a late `VIDEO_ENDED` for the previous video arriving after a skip
        //     or SPA drift already made another video current (stale id), and
        //   - an ad's video element firing `VIDEO_ENDED` while an ad is showing.
        // Either would wrongly mark the active watch concluded and dedupe its
        // real conclusion. When the bridge supplies no id we fall back to the
        // current video (the common floating-window finish).
        let isStaleId = videoId != nil && videoId != self.currentVideo?.videoId
        guard !isStaleId, !self.isShowingAd else {
            self.logger.debug("YouTubePlayer: ignoring ended event (stale id or ad)")
            return false
        }
        if !isNativeTerminal, let eventIssuedAtMilliseconds {
            if Self.isEndEventStale(
                eventIssuedAtMilliseconds: eventIssuedAtMilliseconds,
                lastResumeIssuedAtMilliseconds: self.youtubePlaybackIntentIssuedAtMilliseconds
            ) {
                return false
            }
            if let lastResumeIssuedAtMilliseconds = self.lastResumeIssuedAtMilliseconds,
               Self.isEndEventStale(
                   eventIssuedAtMilliseconds: eventIssuedAtMilliseconds,
                   lastResumeIssuedAtMilliseconds: lastResumeIssuedAtMilliseconds
               )
            {
                return false
            }
        }
        guard self.claimEndedPlaybackOccurrence(
            playbackOccurrence,
            isNativeTerminal: isNativeTerminal
        ) else {
            self.logger.debug("YouTubePlayer: ignoring ended event for stale playback occurrence")
            return false
        }
        if !isNativeTerminal, let eventIssuedAtMilliseconds {
            self.beginYouTubePlaybackIntent(
                issuedAtMilliseconds: eventIssuedAtMilliseconds
            )
        }
        self.isPlaying = false
        self.desiredPlaybackIntent = .paused
        self.isAwaitingResumeConfirmation = false
        self.lastResumeIssuedAtMilliseconds = nil
        self.pendingExplicitStartTarget = nil
        self.pendingUserSeekTarget = nil
        self.finishPlaybackLoading()
        // A finish changes watch history (the video crosses into "finished"), so
        // signal it — this lets Home drop a just-finished video from Continue
        // Watching even when the video ended in the floating window while the
        // user was already sitting on Home (no navigation fires).
        if self.signalWatchConclusion() {
            self.watchActivityGeneration += 1
            self.onVideoEnded?(videoId)
        }
        self.autoplayNextIfEnabled()
        return true
    }

    /// YouTube-style autoplay: when the setting is on, a finished video queues the
    /// next suggested video (the first up-next candidate, or a freshly fetched
    /// related video when none are known — e.g. a floating-window finish) behind a
    /// countdown card, rather than switching immediately. Off by default, so
    /// playback otherwise stops at the end. Mixes and playlists advance through
    /// their own queue via page drift and are unaffected by this.
    private func autoplayNextIfEnabled() {
        guard SettingsManager.shared.youtubeAutoplayEnabled,
              let current = self.currentVideo
        else { return }

        if let next = self.upNext.first {
            self.startAutoplayCountdown(to: next)
            return
        }
        let expectedVideoId = current.videoId
        Task { @MainActor in
            guard let client = self.youtubeClient,
                  let next = try? await client.getWatchNext(videoId: expectedVideoId, playlistId: nil)
                  .related.first(where: { !$0.isShort }),
                  SettingsManager.shared.youtubeAutoplayEnabled,
                  self.currentVideo?.videoId == expectedVideoId,
                  self.autoplayPendingVideo == nil
            else { return }
            self.startAutoplayCountdown(to: next)
        }
    }

    private func startAutoplayCountdown(to next: YouTubeVideo) {
        self.autoplayCountdownTask?.cancel()
        self.autoplayPendingVideo = next
        self.autoplayCountdownRemaining = Self.autoplayCountdownSeconds
        self.autoplayCountdownTask = Task { [weak self] in
            while true {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard let self, self.autoplayPendingVideo?.videoId == next.videoId else { return }
                self.autoplayCountdownRemaining -= 1
                if self.autoplayCountdownRemaining <= 0 {
                    self.confirmAutoplayNow()
                    return
                }
            }
        }
    }

    /// Plays the queued autoplay video right away (the countdown card's play
    /// button — "speed it up").
    func confirmAutoplayNow() {
        guard let next = self.autoplayPendingVideo else { return }
        self.clearAutoplayCountdown()
        self.advance(to: next)
    }

    /// Dismisses the autoplay countdown without advancing (the card's cancel
    /// button, or any explicit playback the user starts instead).
    func cancelAutoplay() {
        self.clearAutoplayCountdown()
    }

    private func clearAutoplayCountdown() {
        self.autoplayCountdownTask?.cancel()
        self.autoplayCountdownTask = nil
        self.autoplayPendingVideo = nil
        self.autoplayCountdownRemaining = 0
    }

    nonisolated static func isEndEventStale(
        eventIssuedAtMilliseconds: Double,
        lastResumeIssuedAtMilliseconds: Double
    ) -> Bool {
        // Bridge timestamps are whole milliseconds while native intent timestamps can be
        // fractional. Equality is ambiguous, so occurrence/generation ownership handles it.
        floor(eventIssuedAtMilliseconds) < floor(lastResumeIssuedAtMilliseconds)
    }

    /// Marks the CURRENT watch as concluded with resume state to reflect and
    /// advances `watchConclusionGeneration` — de-duplicated, so a watch is only
    /// signalled once no matter how many conclusion paths fire for it (a natural
    /// finish followed by an auto-advance drift or a window close would otherwise
    /// double-bump and make Home cancel/restart the refresh the first conclusion
    /// scheduled). Does NOT touch `watchActivityGeneration`: callers bump that
    /// once per watch-state transition (a skip/drift bumps it for the new watch;
    /// a finish/stop bumps it here). Callers that begin a NEW watch (`advance`,
    /// drift) clear `currentWatchConcluded` afterward so the next watch can
    /// signal.
    @discardableResult
    private func signalWatchConclusion() -> Bool {
        guard !self.currentWatchConcluded else { return false }
        self.watchConclusionGeneration += 1
        self.currentWatchConcluded = true
        return true
    }

    func acceptsPlaybackOccurrence(_ occurrence: YouTubePlaybackOccurrence?) -> Bool {
        guard let occurrence else { return true }
        if let lastEndedPlaybackOccurrence,
           !Self.isPlaybackOccurrence(occurrence, newerThan: lastEndedPlaybackOccurrence)
        {
            return false
        }
        guard let currentPlaybackOccurrence else { return true }
        return Self.isPlaybackOccurrence(
            occurrence,
            newerThanOrEqualTo: currentPlaybackOccurrence
        )
    }

    private func bindPlaybackOccurrence(_ occurrence: YouTubePlaybackOccurrence?) {
        guard let occurrence else { return }
        self.currentPlaybackOccurrence = occurrence
    }

    private func claimEndedPlaybackOccurrence(
        _ occurrence: YouTubePlaybackOccurrence?,
        isNativeTerminal: Bool
    ) -> Bool {
        let isResumedNativeTerminal = isNativeTerminal
            && self.currentWatchConcluded
            && self.lastResumeIssuedAtMilliseconds != nil
        guard let occurrence = occurrence ?? self.currentPlaybackOccurrence else {
            // Legacy/test callers without a bridge occurrence remain protected by
            // the watch-level conclusion latch.
            if isResumedNativeTerminal {
                self.currentWatchConcluded = false
                return true
            }
            return !self.currentWatchConcluded
        }
        if let lastEndedPlaybackOccurrence,
           !Self.isPlaybackOccurrence(occurrence, newerThan: lastEndedPlaybackOccurrence)
        {
            guard isResumedNativeTerminal,
                  occurrence == self.currentPlaybackOccurrence
            else { return false }
            self.currentWatchConcluded = false
            return true
        }
        let isNewerThanCurrent = self.currentPlaybackOccurrence.map {
            Self.isPlaybackOccurrence(occurrence, newerThan: $0)
        } ?? true
        if let currentPlaybackOccurrence {
            guard Self.isPlaybackOccurrence(
                occurrence,
                newerThanOrEqualTo: currentPlaybackOccurrence
            ) else { return false }
        }
        if isResumedNativeTerminal || (isNewerThanCurrent && self.currentWatchConcluded) {
            self.currentWatchConcluded = false
        }
        self.currentPlaybackOccurrence = occurrence
        self.lastEndedPlaybackOccurrence = occurrence
        return true
    }

    private func resetPlaybackOccurrenceState() {
        self.currentPlaybackOccurrence = nil
        self.lastEndedPlaybackOccurrence = nil
        self.lastResumeIssuedAtMilliseconds = nil
    }

    private static func isPlaybackOccurrence(
        _ occurrence: YouTubePlaybackOccurrence,
        newerThanOrEqualTo other: YouTubePlaybackOccurrence
    ) -> Bool {
        if occurrence.documentGeneration != other.documentGeneration {
            return occurrence.documentGeneration > other.documentGeneration
        }
        return occurrence.mediaGeneration >= other.mediaGeneration
    }

    private static func isPlaybackOccurrence(
        _ occurrence: YouTubePlaybackOccurrence,
        newerThan other: YouTubePlaybackOccurrence
    ) -> Bool {
        if occurrence.documentGeneration != other.documentGeneration {
            return occurrence.documentGeneration > other.documentGeneration
        }
        return occurrence.mediaGeneration > other.mediaGeneration
    }
}
