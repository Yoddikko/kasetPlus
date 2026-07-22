import Foundation
import Observation

/// View model for the YouTube watch page (metadata + related videos).
@MainActor
@Observable
final class YouTubeWatchViewModel {
    /// Current loading state.
    private(set) var loadingState: LoadingState = .idle

    /// Watch-page companion data.
    private(set) var data: WatchNextData = .empty

    let video: YouTubeVideo
    /// Invalidates stale in-flight loads when a newer one starts
    /// (SwiftUI restarts .task during launch/layout churn; latest wins).
    private var loadGeneration = 0

    let client: any YouTubeClientProtocol
    private let logger = DiagnosticsLogger.api

    init(video: YouTubeVideo, client: any YouTubeClientProtocol) {
        self.video = video
        self.client = client
    }

    // MARK: - Action State (optimistic)

    // Like/dislike and Watch Later live on YouTubePlayerService so the
    // player bar (inline and pop-out) owns them.

    /// Whether the user is subscribed to the channel (seeded from watch-next).
    private(set) var isSubscribed = false
    /// The channel's notification "bell" preference, when subscribed.
    private(set) var notificationPreference: ChannelNotificationPreference?

    // MARK: - Comments State

    /// Loaded comments (top-level threads).
    private(set) var comments: [YouTubeComment] = []

    /// Whether comments are currently loading.
    private(set) var isLoadingComments = false

    /// Token for the next comments page.
    private var commentsContinuation: String?

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

    func load() async {
        self.loadGeneration += 1
        let generation = self.loadGeneration
        self.loadingState = .loading
        do {
            let data = try await self.client.getWatchNext(videoId: self.video.videoId)
            guard generation == self.loadGeneration else { return }
            self.data = data
            self.isSubscribed = data.isSubscribed ?? false
            self.notificationPreference = data.notificationPreference
            self.commentsContinuation = data.commentsContinuation
            self.loadingState = .loaded
            if self.isLive, let liveChat = data.liveChatContinuation {
                self.startLiveChat(continuation: liveChat, generation: generation)
            }
            await self.loadMoreComments()
        } catch {
            guard generation == self.loadGeneration else { return }
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

    // MARK: - Comments

    /// Loads the next page of comments.
    func loadMoreComments() async {
        guard !self.isLoadingComments, let continuation = self.commentsContinuation else { return }

        self.isLoadingComments = true
        defer {
            self.isLoadingComments = false
        }
        do {
            let page = try await self.client.getComments(continuation: continuation)
            guard self.commentsContinuation == continuation else { return }
            let existing = Set(self.comments.map(\.id))
            self.comments.append(contentsOf: page.comments.filter { !existing.contains($0.id) })
            self.commentsContinuation = page.continuation
            if let params = page.createCommentParams {
                self.createCommentParams = params
            }
        } catch {
            if error is CancellationError {
                return
            }
            self.logger.error("Failed to load comments: \(error.localizedDescription)")
            self.commentsContinuation = nil
        }
    }

    /// Toggles a like on a comment (likes, or removes an existing like).
    func likeComment(_ comment: YouTubeComment) async {
        let isLiked = self.likedComments.contains(comment.id)
        guard let action = isLiked ? comment.unlikeAction : comment.likeAction else {
            return
        }
        do {
            try await self.client.performCommentAction(action)
            if isLiked {
                self.likedComments.remove(comment.id)
            } else {
                self.likedComments.insert(comment.id)
                self.dislikedComments.remove(comment.id)
            }
            HapticService.toggle()
        } catch {
            self.logger.error("Failed to toggle comment like: \(error.localizedDescription)")
        }
    }

    /// Toggles a dislike on a comment (dislikes, or removes an existing one).
    func dislikeComment(_ comment: YouTubeComment) async {
        let isDisliked = self.dislikedComments.contains(comment.id)
        guard let action = isDisliked ? comment.undislikeAction : comment.dislikeAction else {
            return
        }
        do {
            try await self.client.performCommentAction(action)
            if isDisliked {
                self.dislikedComments.remove(comment.id)
            } else {
                self.dislikedComments.insert(comment.id)
                self.likedComments.remove(comment.id)
            }
            HapticService.toggle()
        } catch {
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

        self.loadingReplies.insert(comment.id)
        defer {
            self.loadingReplies.remove(comment.id)
        }
        do {
            let page = try await self.client.getComments(continuation: continuation)
            // Reply pages can echo the parent; drop it.
            self.repliesByComment[comment.id] = page.comments.filter { $0.id != comment.id }
        } catch {
            if error is CancellationError {
                return
            }
            self.logger.error("Failed to load replies: \(error.localizedDescription)")
        }
    }

    /// Posts a top-level comment; returns true on success.
    func postComment(text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let params = self.createCommentParams, !self.isPostingComment else {
            return false
        }

        self.isPostingComment = true
        defer {
            self.isPostingComment = false
        }
        do {
            try await self.client.postComment(text: trimmed, createCommentParams: params)
            HapticService.success()
            return true
        } catch {
            self.logger.error("Failed to post comment: \(error.localizedDescription)")
            HapticService.error()
            return false
        }
    }

    // MARK: - Actions

    /// Subscribes/unsubscribes the channel (optimistic with rollback).
    func toggleSubscribed() async {
        guard let channel = self.data.channel else { return }
        let wasSubscribed = self.isSubscribed
        self.isSubscribed = !wasSubscribed
        do {
            try await self.client.setSubscribed(self.isSubscribed, channelId: channel.channelId)
            HapticService.toggle()
        } catch {
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
}
