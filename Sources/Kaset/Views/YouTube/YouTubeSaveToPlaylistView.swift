import SwiftUI

// MARK: - YouTubeSaveToPlaylistView

/// The "Save to…" popover for a YouTube video: the user's playlists (Watch
/// Later + their own), each showing whether the video is already in it, plus an
/// inline "New playlist" creator. Mirrors YouTube's web Save dialog, backed by
/// the same InnerTube endpoints (`playlist/get_add_to_playlist`,
/// `browse/edit_playlist`, `playlist/create`) the app already uses for Watch Later.
///
/// ponytail: add-only for now. Un-saving an arbitrary playlist needs the
/// per-item `setVideoId` that `get_add_to_playlist` doesn't return; wire
/// `removeFromPlaylist` here once we fetch that token (Watch Later already
/// toggles both ways via the player service).
struct YouTubeSaveToPlaylistView: View {
    let videoId: String
    let client: any YouTubeClientProtocol

    @Environment(\.dismiss) private var dismiss

    @State private var options: [AddToPlaylistOption] = []
    @State private var loading = true
    @State private var errorText: String?

    /// Playlists the video was added to during this session (for instant feedback
    /// on top of the server's `isSelected`).
    /// Playlists that currently contain the video (seeded from the server's
    /// `isSelected`, then kept in sync as the user toggles rows).
    @State private var savedIds: Set<String> = []
    @State private var busyIds: Set<String> = []

    // New-playlist inline form.
    @State private var creating = false
    @State private var newTitle = ""
    @State private var newPrivacy: PlaylistPrivacyStatus = .private
    @State private var savingNew = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Save to…", comment: "Header of the save-to-playlist popover")
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            if self.loading {
                self.centered { ProgressView().controlSize(.small) }
            } else if let errorText {
                self.centered {
                    Text(errorText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(self.options) { option in
                            self.row(for: option)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }

            // Always offered: creating a playlist works regardless of the
            // parsed `canCreatePlaylist` flag (unreliable on the youtube.com feed).
            if !self.loading, self.errorText == nil {
                Divider()
                self.newPlaylistFooter
            }
        }
        // Fixed size on purpose: a resizing popover triggers an NSPopover
        // animated window-resize crash (EXC_BAD_ACCESS in updateAnimatedWindowSize)
        // when the "New playlist" form appears. A stable size sidesteps it.
        .frame(width: 380, height: 440, alignment: .top)
        .task { await self.load() }
    }

    // MARK: Rows

    private func row(for option: AddToPlaylistOption) -> some View {
        let isSaved = self.savedIds.contains(option.playlistId)
        let isBusy = self.busyIds.contains(option.playlistId)
        return Button {
            Task { await self.toggle(option, isSaved: isSaved) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: self.icon(for: option))
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(option.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if let subtitle = self.privacyLabel(option.privacyStatus) ?? option.subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)

                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: isSaved ? "checkmark" : "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isSaved ? SettingsManager.shared.accentColor : .secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }

    private var newPlaylistFooter: some View {
        Group {
            if self.creating {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(String(localized: "Playlist name", comment: "New playlist name field"), text: self.$newTitle)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Picker("", selection: self.$newPrivacy) {
                            Text("Private", comment: "Playlist privacy").tag(PlaylistPrivacyStatus.private)
                            Text("Unlisted", comment: "Playlist privacy").tag(PlaylistPrivacyStatus.unlisted)
                            Text("Public", comment: "Playlist privacy").tag(PlaylistPrivacyStatus.public)
                        }
                        .labelsHidden()
                        .fixedSize()
                        Spacer()
                        Button {
                            Task { await self.createPlaylist() }
                        } label: {
                            if self.savingNew {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Create", comment: "Create playlist button")
                            }
                        }
                        .disabled(self.newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || self.savingNew)
                    }
                }
                .padding(16)
            } else {
                Button {
                    self.creating = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "plus")
                        Text("New playlist", comment: "Create a new playlist from the save popover")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func centered(@ViewBuilder _ content: () -> some View) -> some View {
        HStack { Spacer(); content(); Spacer() }
            .frame(height: 90)
    }

    // MARK: Actions

    private func load() async {
        do {
            let menu = try await self.client.getAddToPlaylistOptions(videoId: self.videoId)
            self.options = menu.options
            self.savedIds = Set(menu.options.filter(\.isSelected).map(\.playlistId))
        } catch {
            self.errorText = String(localized: "Couldn't load your playlists.", comment: "Save popover load error")
        }
        self.loading = false
    }

    private func toggle(_ option: AddToPlaylistOption, isSaved: Bool) async {
        self.busyIds.insert(option.playlistId)
        defer { self.busyIds.remove(option.playlistId) }
        do {
            if isSaved {
                try await self.client.removeFromPlaylist(videoId: self.videoId, playlistId: option.playlistId)
                self.savedIds.remove(option.playlistId)
            } else {
                try await self.client.addToPlaylist(videoId: self.videoId, playlistId: option.playlistId)
                self.savedIds.insert(option.playlistId)
            }
        } catch {
            self.errorText = String(localized: "Couldn't update that playlist.", comment: "Save popover toggle error")
        }
    }

    private func createPlaylist() async {
        let title = self.newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        self.savingNew = true
        defer { self.savingNew = false }
        do {
            _ = try await self.client.createPlaylist(
                title: title,
                privacyStatus: self.newPrivacy,
                videoIds: [self.videoId]
            )
            self.dismiss()
        } catch {
            self.errorText = String(localized: "Couldn't create the playlist.", comment: "Save popover create error")
        }
    }

    // MARK: Helpers

    private func icon(for option: AddToPlaylistOption) -> String {
        switch option.privacyStatus {
        case .private: "lock"
        case .unlisted: "link"
        case .public: "globe"
        case nil: "list.bullet"
        }
    }

    private func privacyLabel(_ status: PlaylistPrivacyStatus?) -> String? {
        switch status {
        case .private: String(localized: "Private", comment: "Playlist privacy")
        case .unlisted: String(localized: "Unlisted", comment: "Playlist privacy")
        case .public: String(localized: "Public", comment: "Playlist privacy")
        case nil: nil
        }
    }
}
