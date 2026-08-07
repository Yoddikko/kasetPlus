import Foundation
import Observation

// MARK: - YouTubeAskAccountScopeObservation

/// In-memory observation key for watch-page account changes. The raw scope is
/// never persisted or rendered; it only restarts the Ask bootstrap request.
struct YouTubeAskAccountScopeObservation: Hashable, Sendable {
    let authenticationGeneration: UInt64
    let hasPersonalAccount: Bool
    let accountScopeID: String?
    let isPrimaryAccount: Bool?
    let verifiedIdentitySequence: Int
}

// MARK: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable

extension YouTubeAskAccountScopeObservation: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String {
        "<redacted YouTube Ask account scope>"
    }

    var debugDescription: String {
        self.description
    }

    var customMirror: Mirror {
        Mirror(reflecting: self.description)
    }
}

// MARK: - YouTubeWatchViewModel

/// View model for the YouTube watch page (metadata + related videos).
@MainActor
@Observable
final class YouTubeWatchViewModel {
    /// Current loading state.
    private(set) var loadingState: LoadingState = .idle

    /// Watch-page companion data.
    private(set) var data: WatchNextData = .empty

    /// Watch-scoped Ask Gemini state. The child owns all of its request tasks
    /// and opaque conversation state.
    let ask: YouTubeAskViewModel

    let video: YouTubeVideo
    /// Invalidates stale in-flight loads when a newer one starts
    /// (SwiftUI restarts .task during launch/layout churn; latest wins).
    private var loadGeneration = 0
    private var lastAskAccountScope: YouTubeAskAccountScopeObservation?

    let client: any YouTubeClientProtocol
    private let logger = DiagnosticsLogger.api

    init(video: YouTubeVideo, client: any YouTubeClientProtocol) {
        self.video = video
        self.client = client
        self.ask = YouTubeAskViewModel(videoID: video.videoId, client: client)
    }

    // MARK: - Action State (optimistic)

    // Like/dislike and Watch Later live on YouTubePlayerService so the
    // player bar (inline and pop-out) owns them.

    /// Whether the user is subscribed to the channel (seeded from watch-next).
    private(set) var isSubscribed = false

    /// Members-only gate: YouTube's real "unplayable" notice for a members-only
    /// video the signed-in user can't watch. Nil when the video is playable or
    /// isn't members-only, so the watch surface shows the video (or its spinner).
    private(set) var membersGate: YouTubePlayability?
    /// The channel's notification "bell" preference, when subscribed.
    private(set) var notificationPreference: ChannelNotificationPreference?

    /// Credited channels on a collaboration upload (empty for single-owner videos).
    private(set) var collaborators: [VideoCollaborator] = []
    /// Live subscribed state per collaborator channel (optimistic; seeded from load).
    private(set) var collaboratorSubscribed: [String: Bool] = [:]
    /// Live notification "bell" preference per collaborator channel.
    private(set) var collaboratorNotification: [String: ChannelNotificationPreference] = [:]

    // MARK: - Comments State

    /// Loaded comments (top-level threads).
    private(set) var comments: [YouTubeComment] = []

    /// Whether comments are currently loading.
    private(set) var isLoadingComments = false

    /// Token for the next comments page.
    private var commentsContinuation: String?
    private var commentsGeneration = 0

    /// The single in-flight comments page, shared by concurrent callers so a
    /// SwiftUI watch-task restart adopts the initial request instead of
    /// cancelling it with the outer task or issuing a duplicate request.
    private var commentsLoadTask: Task<CommentsLoadOutcome, Never>?

    /// Distinguishes watch initialization from explicit comment pagination.
    /// Once the first page reaches a terminal result, repeated watch-task runs
    /// preserve loaded watch/Ask state without automatically fetching page two.
    private var didCompleteInitialCommentsLoad = false

    /// How the comments are ordered.
    enum CommentSort { case top, newest }

    /// Current comment ordering, and the sort tokens captured from the first
    /// comments page (nil until loaded / when the video exposes no sort menu).
    private(set) var commentSort: CommentSort = .top
    private var sortTopToken: String?
    private var sortNewestToken: String?

    /// Whether the comment sort control should be offered.
    var canSortComments: Bool {
        self.sortTopToken != nil && self.sortNewestToken != nil
    }

    /// Params for posting a comment (nil = signed out / disabled).
    private(set) var createCommentParams: String?

    /// Whether a comment is currently being posted.
    private(set) var isPostingComment = false

    var canLoadMoreComments: Bool {
        self.commentsContinuation != nil
    }

    var canComment: Bool {
        self.createCommentParams != nil
    }

    /// Comments the user liked/disliked this session (display state only —
    /// undo tokens aren't tracked, so actions are one-shot).
    private(set) var likedComments: Set<String> = []
    private(set) var dislikedComments: Set<String> = []

    /// Loaded reply threads by parent comment ID.
    private(set) var repliesByComment: [String: [YouTubeComment]] = [:]

    /// Parent comments whose replies are currently loading.
    private(set) var loadingReplies: Set<String> = []

    // MARK: - Live Chat State

    /// Whether this video is a live stream.
    var isLive: Bool { self.video.isLive }

    /// Live-chat messages accumulated while polling (oldest first, capped).
    private(set) var liveChatMessages: [YouTubeLiveChatMessage] = []

    /// The running live-chat poll loop, if any.
    private var liveChatTask: Task<Void, Never>?

    /// Whether at least one live-chat poll has completed (used to tell "loading"
    /// apart from a genuinely empty chat).
    private(set) var liveChatLoaded = false

    /// Send-message params for the current chat (nil = can't post: signed out or
    /// restricted). Refreshed each poll.
    private(set) var liveChatSendParams: String?

    /// Whether a live-chat message is currently being sent.
    private(set) var isSendingLiveChat = false

    /// Whether the signed-in user can post to this live chat.
    var canSendLiveChat: Bool {
        self.liveChatSendParams != nil
    }

    /// Whether the live chat is available for this video (live + chat enabled).
    var hasLiveChat: Bool {
        self.isLive && self.data.liveChatContinuation != nil
    }

    func load(accountScope: YouTubeAskAccountScopeObservation? = nil) async {
        let accountScopeChanged: Bool
        if let accountScope {
            accountScopeChanged = self.lastAskAccountScope.map { $0 != accountScope } ?? false
            self.lastAskAccountScope = accountScope
        } else {
            accountScopeChanged = false
        }

        if accountScopeChanged {
            self.resetAccountScopedWatchState()
        }

        if self.loadingState == .loaded {
            await self.loadInitialCommentsIfNeeded()
            return
        }
        self.loadGeneration += 1
        let generation = self.loadGeneration
        self.ask.cancelAndDiscard()
        self.loadingState = .loading
        self.membersGate = nil
        do {
            let page = try await self.loadWatchPageWithIdentityRetry(generation: generation)
            guard generation == self.loadGeneration else { return }
            let data = page.data
            self.data = data
            self.isSubscribed = data.isSubscribed ?? false
            self.notificationPreference = data.notificationPreference
            self.collaborators = data.collaborators
            self.collaboratorSubscribed = Dictionary(
                data.collaborators.map { ($0.channelId, $0.isSubscribed) },
                uniquingKeysWith: { first, _ in first }
            )
            self.collaboratorNotification = Dictionary(
                data.collaborators.compactMap { collaborator in
                    collaborator.notification.map { (collaborator.channelId, $0) }
                },
                uniquingKeysWith: { first, _ in first }
            )
            self.commentsContinuation = data.commentsContinuation
            self.didCompleteInitialCommentsLoad = false
            self.ask.seed(page.askBootstrap)
            self.loadingState = .loaded
            if self.isLive, let liveChat = data.liveChatContinuation {
                self.startLiveChat(continuation: liveChat, generation: generation)
            }
            // Members-only videos never serve a stream to non-members, so the
            // player just spins forever. Ask YouTube's `player` endpoint for the
            // real reason and surface it as a gate instead.
            if self.video.isMembersOnly {
                await self.loadMembersGate(generation: generation)
            }
            await self.loadInitialCommentsIfNeeded()
        } catch {
            guard generation == self.loadGeneration else { return }
            self.ask.cancelAndDiscard()
            // A cancelled load (view went away mid-flight) is not an
            // error; reset so the next task run reloads.
            if error is CancellationError {
                self.loadingState = .idle
                return
            }
            self.logger.error("Failed to load watch-next data: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    /// Fetches YouTube's playability status for a members-only video and, if the
    /// signed-in user can't play it, stores the gate so the surface shows the
    /// real notice + a "Join" (Abbonati) action instead of an endless spinner.
    /// Non-fatal: any failure just falls back to the existing loading state.
    private func loadMembersGate(generation: Int) async {
        do {
            let playability = try await self.client.getPlayability(videoId: self.video.videoId)
            guard generation == self.loadGeneration else { return }
            self.membersGate = playability.isPlayable ? nil : playability
        } catch {
            self.logger.debug("Members-only playability check failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Live Chat

    /// Polls the live chat, appending new messages after each server-provided
    /// `timeoutMs`, until the video changes (generation bumps) or it's stopped.
    private func startLiveChat(continuation: String, generation: Int) {
        self.liveChatTask?.cancel()
        self.liveChatTask = Task { [weak self] in
            var token: String? = continuation
            while let current = token, !Task.isCancelled {
                guard let self, generation == self.loadGeneration else { return }
                do {
                    let page = try await self.client.getLiveChat(continuation: current)
                    guard generation == self.loadGeneration, !Task.isCancelled else { return }
                    self.appendLiveChat(page.messages)
                    // Send params usually appear only on the first page; keep them
                    // once found so the composer doesn't flicker away on later polls.
                    if let params = page.sendParams {
                        self.liveChatSendParams = params
                    }
                    self.liveChatLoaded = true
                    token = page.continuation
                    // Clamp the server delay to a sane range so a bad value can't
                    // hammer the endpoint or stall the chat.
                    try await Task.sleep(for: .milliseconds(min(max(page.timeoutMs, 1000), 10000)))
                } catch {
                    if error is CancellationError { return }
                    // Transient failure: back off and retry with the same token.
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
    }

    private func appendLiveChat(_ messages: [YouTubeLiveChatMessage]) {
        let existing = Set(self.liveChatMessages.map(\.id))
        let fresh = messages.filter { !existing.contains($0.id) }
        guard !fresh.isEmpty else { return }
        self.liveChatMessages.append(contentsOf: fresh)
        // Cap memory on long-running streams; keep the most recent messages.
        if self.liveChatMessages.count > 250 {
            self.liveChatMessages.removeFirst(self.liveChatMessages.count - 250)
        }
    }

    /// Stops the live-chat poll loop (call when the watch view goes away).
    func stopLiveChat() {
        self.liveChatTask?.cancel()
        self.liveChatTask = nil
    }

    /// Sends a live-chat message; returns true on success. The message shows up
    /// on the next poll like any other, so nothing is appended optimistically.
    func sendLiveChatMessage(text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let params = self.liveChatSendParams, !self.isSendingLiveChat else {
            return false
        }

        self.isSendingLiveChat = true
        defer { self.isSendingLiveChat = false }
        do {
            try await self.client.sendLiveChatMessage(text: trimmed, params: params)
            HapticService.success()
            return true
        } catch {
            self.logger.error("Failed to send live chat message: \(error.localizedDescription)")
            HapticService.error()
            return false
        }
    }

    /// A scope publication can reset the shared client after a watch response
    /// parses but before its final identity fence. Retry that read-only `next`
    /// request once when the outer route task and load generation are still
    /// current. Panel materialization and suggestion submission are never retried.
    private func loadWatchPageWithIdentityRetry(
        generation: Int
    ) async throws -> YouTubeWatchPage {
        do {
            return try await self.client.getWatchPage(videoId: self.video.videoId, playlistId: self.video.mixPlaylistId)
        } catch is CancellationError {
            guard !Task.isCancelled, generation == self.loadGeneration else {
                throw CancellationError()
            }
            await Task.yield()
            guard !Task.isCancelled, generation == self.loadGeneration else {
                throw CancellationError()
            }
            return try await self.client.getWatchPage(videoId: self.video.videoId, playlistId: self.video.mixPlaylistId)
        }
    }

    /// Invalidates the current route load and discards all Ask state.
    func cancel() {
        self.loadGeneration += 1
        self.commentsLoadTask?.cancel()
        self.commentsLoadTask = nil
        self.commentsGeneration += 1
        self.didCompleteInitialCommentsLoad = false
        self.isLoadingComments = false
        self.isPostingComment = false
        self.commentsContinuation = nil
        self.loadingReplies = []
        self.ask.cancelAndDiscard()
        self.loadingState = .idle
    }

    private func resetAccountScopedWatchState() {
        self.loadGeneration += 1
        self.commentsLoadTask?.cancel()
        self.commentsLoadTask = nil
        self.commentsGeneration += 1
        self.didCompleteInitialCommentsLoad = false
        self.data = .empty
        self.ask.cancelAndDiscard()
        self.isSubscribed = false
        self.comments = []
        self.isLoadingComments = false
        self.commentsContinuation = nil
        self.createCommentParams = nil
        self.isPostingComment = false
        self.likedComments = []
        self.dislikedComments = []
        self.repliesByComment = [:]
        self.loadingReplies = []
        self.loadingState = .idle
    }

    // MARK: - Comments

    private enum CommentsLoadOutcome {
        case completed
        case cancelled
        case unavailable
    }

    /// Loads the first comments page once for watch initialization. A restarted
    /// outer `.task` coalesces onto the stored page request, while later task
    /// runs remain no-ops after that first page reaches a terminal result.
    private func loadInitialCommentsIfNeeded() async {
        guard !self.didCompleteInitialCommentsLoad else { return }
        _ = await self.loadCommentsPage()
    }

    /// Loads the next page of comments.
    func loadMoreComments() async {
        _ = await self.loadCommentsPage()
    }

    /// Coalesces every caller for the current comments page onto one
    /// unstructured task. The task survives cancellation of an awaiting SwiftUI
    /// `.task`; only an explicit route/account reset cancels it.
    private func loadCommentsPage() async -> CommentsLoadOutcome {
        if let existing = self.commentsLoadTask {
            return await existing.value
        }
        guard let continuation = self.commentsContinuation else {
            self.didCompleteInitialCommentsLoad = true
            return .unavailable
        }

        let generation = self.commentsGeneration
        let marksInitialCompletion = !self.didCompleteInitialCommentsLoad
        let task = Task {
            await self.performCommentsLoad(
                continuation: continuation,
                generation: generation,
                marksInitialCompletion: marksInitialCompletion
            )
        }
        self.commentsLoadTask = task
        return await task.value
    }

    private func performCommentsLoad(
        continuation: String,
        generation: Int,
        marksInitialCompletion: Bool
    ) async -> CommentsLoadOutcome {
        defer {
            if generation == self.commentsGeneration {
                self.commentsLoadTask = nil
                self.isLoadingComments = false
            }
        }
        guard generation == self.commentsGeneration, !Task.isCancelled else {
            return .cancelled
        }
        self.isLoadingComments = true
        do {
            let page = try await self.client.getComments(continuation: continuation)
            guard generation == self.commentsGeneration,
                  self.commentsContinuation == continuation
            else { return .cancelled }
            let existing = Set(self.comments.map(\.id))
            self.comments.append(contentsOf: page.comments.filter { !existing.contains($0.id) })
            self.commentsContinuation = page.continuation
            if let params = page.createCommentParams {
                self.createCommentParams = params
            }
            // The sort menu only rides along on the first page.
            if let top = page.sortTopToken { self.sortTopToken = top }
            if let newest = page.sortNewestToken { self.sortNewestToken = newest }
            if marksInitialCompletion {
                self.didCompleteInitialCommentsLoad = true
            }
            return .completed
        } catch {
            if error is CancellationError {
                return .cancelled
            }
            guard generation == self.commentsGeneration else { return .cancelled }
            self.logger.error("Failed to load comments: \(error.localizedDescription)")
            self.commentsContinuation = nil
            if marksInitialCompletion {
                self.didCompleteInitialCommentsLoad = true
            }
            return .completed
        }
    }

    /// Re-orders the comments (Top / Newest) by restarting the list from the
    /// matching sort token.
    func setCommentSort(_ sort: CommentSort) async {
        guard sort != self.commentSort else { return }
        guard let token = (sort == .top) ? self.sortTopToken : self.sortNewestToken else { return }
        self.commentSort = sort
        self.comments = []
        self.commentsContinuation = token
        await self.loadMoreComments()
    }

    /// Toggles a like on a comment (likes, or removes an existing like).
    func likeComment(_ comment: YouTubeComment) async {
        let isLiked = self.likedComments.contains(comment.id)
        guard let action = isLiked ? comment.unlikeAction : comment.likeAction else {
            return
        }
        let generation = self.commentsGeneration
        do {
            try await self.client.performCommentAction(action)
            guard generation == self.commentsGeneration else { return }
            if isLiked {
                self.likedComments.remove(comment.id)
            } else {
                self.likedComments.insert(comment.id)
                self.dislikedComments.remove(comment.id)
            }
            HapticService.toggle()
        } catch {
            guard generation == self.commentsGeneration else { return }
            self.logger.error("Failed to toggle comment like: \(error.localizedDescription)")
        }
    }

    /// Toggles a dislike on a comment (dislikes, or removes an existing one).
    func dislikeComment(_ comment: YouTubeComment) async {
        let isDisliked = self.dislikedComments.contains(comment.id)
        guard let action = isDisliked ? comment.undislikeAction : comment.dislikeAction else {
            return
        }
        let generation = self.commentsGeneration
        do {
            try await self.client.performCommentAction(action)
            guard generation == self.commentsGeneration else { return }
            if isDisliked {
                self.dislikedComments.remove(comment.id)
            } else {
                self.dislikedComments.insert(comment.id)
                self.likedComments.remove(comment.id)
            }
            HapticService.toggle()
        } catch {
            guard generation == self.commentsGeneration else { return }
            self.logger.error("Failed to toggle comment dislike: \(error.localizedDescription)")
        }
    }

    /// Loads a comment's reply thread.
    func loadReplies(for comment: YouTubeComment) async {
        guard let continuation = comment.repliesContinuation,
              self.repliesByComment[comment.id] == nil,
              !self.loadingReplies.contains(comment.id)
        else {
            return
        }

        let generation = self.commentsGeneration
        self.loadingReplies.insert(comment.id)
        defer {
            if generation == self.commentsGeneration {
                self.loadingReplies.remove(comment.id)
            }
        }
        do {
            let page = try await self.client.getComments(continuation: continuation)
            guard generation == self.commentsGeneration else { return }
            // Reply pages can echo the parent; drop it.
            self.repliesByComment[comment.id] = page.comments.filter { $0.id != comment.id }
        } catch {
            if error is CancellationError {
                return
            }
            guard generation == self.commentsGeneration else { return }
            self.logger.error("Failed to load replies: \(error.localizedDescription)")
        }
    }

    /// Posts a top-level comment; returns true on success.
    func postComment(text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let params = self.createCommentParams, !self.isPostingComment else {
            return false
        }

        let generation = self.commentsGeneration
        self.isPostingComment = true
        defer {
            if generation == self.commentsGeneration {
                self.isPostingComment = false
            }
        }
        do {
            try await self.client.postComment(text: trimmed, createCommentParams: params)
            guard generation == self.commentsGeneration else { return false }
            HapticService.success()
            return true
        } catch {
            guard generation == self.commentsGeneration else { return false }
            self.logger.error("Failed to post comment: \(error.localizedDescription)")
            HapticService.error()
            return false
        }
    }

    // MARK: - Actions

    /// Subscribes/unsubscribes the channel (optimistic with rollback).
    func toggleSubscribed() async {
        guard let channel = self.data.channel else { return }
        let generation = self.loadGeneration
        let wasSubscribed = self.isSubscribed
        self.isSubscribed = !wasSubscribed
        do {
            try await self.client.setSubscribed(self.isSubscribed, channelId: channel.channelId)
            guard generation == self.loadGeneration else { return }
            HapticService.toggle()
        } catch {
            guard generation == self.loadGeneration else { return }
            self.logger.error("Failed to change subscription: \(error.localizedDescription)")
            self.isSubscribed = wasSubscribed
        }
    }

    /// Applies a notification "bell" preference for the channel (optimistic with
    /// rollback). `option` comes from `notificationPreference.options`.
    func setNotificationPreference(_ option: ChannelNotificationPreference.Option) async {
        guard let preference = self.notificationPreference else { return }
        let previous = preference
        self.notificationPreference = ChannelNotificationPreference(
            channelId: preference.channelId,
            options: preference.options.map {
                ChannelNotificationPreference.Option(
                    level: $0.level, label: $0.label, params: $0.params, isCurrent: $0.params == option.params
                )
            },
            unsubscribeLabel: preference.unsubscribeLabel
        )
        do {
            try await self.client.modifyNotificationPreference(params: option.params)
            HapticService.toggle()
        } catch {
            self.logger.error("Failed to change notification preference: \(error.localizedDescription)")
            self.notificationPreference = previous
        }
    }

    // MARK: - Collaborators

    /// Whether the signed-in user is subscribed to a collaborator's channel.
    func isSubscribed(toCollaborator channelId: String) -> Bool {
        self.collaboratorSubscribed[channelId] ?? false
    }

    /// Subscribes/unsubscribes a single collaborator (optimistic with rollback).
    func toggleSubscribed(collaborator: VideoCollaborator) async {
        let wasSubscribed = self.isSubscribed(toCollaborator: collaborator.channelId)
        self.collaboratorSubscribed[collaborator.channelId] = !wasSubscribed
        do {
            try await self.client.setSubscribed(!wasSubscribed, channelId: collaborator.channelId)
            HapticService.toggle()
        } catch {
            self.logger.error("Failed to change collaborator subscription: \(error.localizedDescription)")
            self.collaboratorSubscribed[collaborator.channelId] = wasSubscribed
        }
    }

    /// Applies a notification "bell" preference for a single collaborator
    /// (optimistic with rollback).
    func setNotificationPreference(
        _ option: ChannelNotificationPreference.Option,
        forCollaborator channelId: String
    ) async {
        guard let preference = self.collaboratorNotification[channelId] else { return }
        let previous = preference
        self.collaboratorNotification[channelId] = ChannelNotificationPreference(
            channelId: preference.channelId,
            options: preference.options.map {
                ChannelNotificationPreference.Option(
                    level: $0.level, label: $0.label, params: $0.params, isCurrent: $0.params == option.params
                )
            },
            unsubscribeLabel: preference.unsubscribeLabel
        )
        do {
            try await self.client.modifyNotificationPreference(params: option.params)
            HapticService.toggle()
        } catch {
            self.logger.error("Failed to change collaborator notification preference: \(error.localizedDescription)")
            self.collaboratorNotification[channelId] = previous
        }
    }
}
