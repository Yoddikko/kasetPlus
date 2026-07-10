import SwiftUI

// MARK: - YouTubeDownloadSheet

struct YouTubeDownloadSheet: View {
    let videoId: String
    let videoTitle: String

    @Environment(\.dismiss) private var dismiss
    @State private var formats: [YouTubeDownloadService.DownloadFormat] = []
    @State private var downloadState: YouTubeDownloadService.DownloadState = .idle
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Download", comment: "Download sheet title")
                    .font(.headline)
                Spacer()
                if case .downloading = self.downloadState {
                    Button(String(localized: "Cancel")) {
                        YouTubeDownloadService.shared.cancelDownload()
                        self.dismiss()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                } else {
                    Button {
                        self.dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Text(self.videoTitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 20)

            Divider()
                .padding(.vertical, 12)

            // Content
            Group {
                switch self.downloadState {
                case .idle:
                    if self.isLoading {
                        ProgressView(String(localized: "Fetching formats..."))
                            .padding(.top, 40)
                    } else if let error = self.errorMessage {
                        self.errorView(error)
                    } else {
                        self.formatList
                    }

                case .preparing:
                    ProgressView(String(localized: "Preparing download..."))
                        .padding(.top, 40)

                case let .downloading(progress, speed):
                    self.progressView(progress: progress, speed: speed)

                case let .completed(filename):
                    self.completedView(filename: filename)

                case let .failed(error):
                    self.errorView(error)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 400, height: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            self.formats = await YouTubeDownloadService.shared.fetchFormats(videoId: self.videoId)
            self.isLoading = false
            if self.formats.count <= 1 { // only mp3
                self.errorMessage = String(localized: "No formats available. Is yt-dlp installed?")
            }
        }
    }

    // MARK: - Subviews

    private var formatList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Select quality", comment: "Download quality picker header")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(self.formats) { format in
                        Button {
                            self.startDownload(format: format)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: format.isAudioOnly ? "music.note" : "film")
                                    .font(.title3)
                                    .foregroundStyle(format.isAudioOnly ? .green : Color.accentColor)
                                    .frame(width: 28)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(format.label)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.primary)
                                    if !format.sizeLabel.isEmpty {
                                        Text(format.sizeLabel)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()

                                Image(systemName: "arrow.down.circle")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(12)
                            .background {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.secondary.opacity(0.06))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
    }

    private func progressView(progress: Double, speed: String) -> some View {
        VStack(spacing: 20) {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .padding(.horizontal, 40)

            Text("\(Int(progress * 100))%")
                .font(.title2.monospacedDigit().bold())

            if !speed.isEmpty {
                Text(speed)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("Downloading to Downloads/KasetPlus/", comment: "Download destination hint")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 40)
    }

    private func completedView(filename: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("Download complete", comment: "Download success message")
                .font(.title3.bold())

            Text(filename)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Button(String(localized: "Show in Finder")) {
                let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
                    .appendingPathComponent("KasetPlus")
                NSWorkspace.shared.open(dir)
                self.dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.top, 40)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            if !YouTubeDownloadService.shared.isAvailable {
                Button(String(localized: "Install yt-dlp")) {
                    NSWorkspace.shared.open(URL(string: "https://brew.sh")!)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Text("Run: brew install yt-dlp", comment: "yt-dlp install hint")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 40)
    }

    // MARK: - Actions

    private func startDownload(format: YouTubeDownloadService.DownloadFormat) {
        YouTubeDownloadService.shared.download(
            videoId: self.videoId,
            format: format
        ) { state in
            Task { @MainActor in
                self.downloadState = state
            }
        }
    }
}
