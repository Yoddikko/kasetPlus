import SwiftUI

// MARK: - YouTubeSearchView

/// YouTube search: query field, result-kind filter, and mixed result list.
struct YouTubeSearchView: View {
    @Bindable var viewModel: YouTubeSearchViewModel
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            self.searchHeader

            Group {
                switch self.viewModel.loadingState {
                case .idle:
                    self.emptyState
                case .loading:
                    LoadingView()
                case let .error(error):
                    ErrorView(
                        title: error.title,
                        message: error.message,
                        isRetryable: error.isRetryable
                    ) {
                        Task {
                            await self.viewModel.search()
                        }
                    }
                case .loaded, .loadingMore:
                    if self.viewModel.results.isEmpty {
                        ContentUnavailableView.search(text: self.viewModel.query)
                    } else {
                        self.resultsList
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(Text("Search", comment: "YouTube search title"))
    }

    // MARK: - Header

    private var searchHeader: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField(
                    String(localized: "Search YouTube"),
                    text: self.$viewModel.query
                )
                .textFieldStyle(.plain)
                .focused(self.$isSearchFieldFocused)
                .onSubmit {
                    Task {
                        await self.viewModel.search()
                    }
                }
                .accessibilityIdentifier(AccessibilityID.YouTubeContent.searchField)

                if !self.viewModel.query.isEmpty {
                    Button {
                        self.viewModel.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Clear search"))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.5), in: Capsule())
            .padding(.horizontal, 20)

            // Full-width so the filter chips can scroll edge-to-edge.
            if !self.viewModel.filterGroups.isEmpty {
                self.filterBar
            }
        }
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    // MARK: - Filter Bar

    /// A horizontal row of glass-capsule menus, one per YouTube filter group
    /// (Type, Upload date, Duration, Features, Sort by), plus a Clear chip.
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(self.viewModel.filterGroups) { group in
                    self.filterMenu(group)
                }

                if self.viewModel.hasActiveFilters {
                    Button {
                        self.viewModel.clearFilters()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Clear", comment: "Clear search filters")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .compatGlass(interactive: true, tint: nil, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Clear filters"))
                }
            }
            .padding(.horizontal, 20)
        }
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.searchFilter)
    }

    private func filterMenu(_ group: YouTubeSearchFilterGroup) -> some View {
        // A filter is "active" only when its selected option carries params
        // (YouTube marks a default no-op like "Relevance" selected with no endpoint).
        let selected = group.selectedOption
        let isActive = selected?.params != nil

        return Menu {
            ForEach(group.options) { option in
                Button {
                    self.viewModel.applyFilter(option)
                } label: {
                    if option.isSelected {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
                .disabled(option.isDisabled)
            }
        } label: {
            HStack(spacing: 5) {
                Text(isActive ? (selected?.label ?? group.title) : group.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .compatGlass(interactive: true, tint: isActive ? Color.accentColor : nil, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(String(localized: "Search YouTube"), systemImage: "magnifyingglass")
        } description: {
            Text("Find videos, channels, and playlists.", comment: "YouTube search empty state")
        }
    }

    // MARK: - Results

    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                // Render results in YouTube's own mixed order so mixes and
                // playlists surface inline instead of being buried below the
                // infinite video list.
                ForEach(self.viewModel.results.items) { item in
                    self.row(for: item)
                }

                if self.viewModel.results.continuation != nil {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .task(id: self.viewModel.results.continuation) {
                            await self.viewModel.loadMore()
                        }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.searchResults)
    }

    @ViewBuilder
    private func row(for item: YouTubeSearchItem) -> some View {
        switch item {
        case let .channel(channel):
            NavigationLink(value: YouTubeRoute.channel(channelId: channel.channelId)) {
                ChannelRowView(channel: channel)
            }
            .buttonStyle(.interactiveRow)
        case let .video(video):
            NavigationLink(value: YouTubeRoute.watch(video)) {
                VideoRowView(video: video)
            }
            .buttonStyle(.interactiveRow)
        case let .playlist(playlist):
            NavigationLink(
                value: playlist.watchTarget.map(YouTubeRoute.watch)
                    ?? YouTubeRoute.playlist(playlistId: playlist.playlistId)
            ) {
                YouTubePlaylistRowView(playlist: playlist)
            }
            .buttonStyle(.interactiveRow)
        }
    }
}

// MARK: - AccessibilityID Additions

extension AccessibilityID.YouTubeContent {
    static let searchField = "youtubeContent.searchField"
    static let searchFilter = "youtubeContent.searchFilter"
    static let searchResults = "youtubeContent.searchResults"
}
