import Foundation

// MARK: - YouTubeDownloadService

/// Wraps `yt-dlp` for downloading YouTube videos.
/// Requires yt-dlp installed (e.g. `brew install yt-dlp`).
@MainActor
final class YouTubeDownloadService {
    static let shared = YouTubeDownloadService()

    private let downloadsDir: URL = {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            .appendingPathComponent("KasetPlus")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() {}

    // MARK: - yt-dlp binary path

    /// Bundled yt-dlp binary (included in app Resources by build script).
    /// Falls back to system-installed yt-dlp and common paths.
    private var ytdlpPath: String? {
        // 1. Direct resource path (more reliable than path(forResource:) for extensionless files)
        if let resourcePath = Bundle.main.resourcePath {
            let bundledPath = (resourcePath as NSString).appendingPathComponent("yt-dlp")
            if FileManager.default.isExecutableFile(atPath: bundledPath) {
                return bundledPath
            }
        }
        // 2. path(forResource:) as fallback
        if let path = Bundle.main.path(forResource: "yt-dlp", ofType: nil),
           FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // 3. System-installed yt-dlp (Homebrew, etc.)
        for sysPath in ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"] {
            if FileManager.default.isExecutableFile(atPath: sysPath) {
                return sysPath
            }
        }
        // 4. PATH lookup
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        which.arguments = ["which", "yt-dlp"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = FileHandle.nullDevice
        do {
            try which.run()
            which.waitUntilExit()
            let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        } catch {}
        return nil
    }

    /// Whether yt-dlp is reachable (bundled or system).
    var isAvailable: Bool {
        guard let path = ytdlpPath else { return false }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    // MARK: - Formats

    struct DownloadFormat: Identifiable {
        let id: String           // yt-dlp format code
        let label: String        // "1080p (mp4)" / "MP3 (audio)"
        let isAudioOnly: Bool
        let fileSize: Int64?     // bytes, nil if unknown
        var sizeLabel: String {
            guard let size = fileSize else { return "" }
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return formatter.string(fromByteCount: size)
        }
    }

    /// Fetches available download formats for a YouTube video.
    func fetchFormats(videoId: String) async -> [DownloadFormat] {
        guard let ytdlpPath, let url = URL(string: "https://www.youtube.com/watch?v=\(videoId)") else { return [] }

        return await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ytdlpPath)
            proc.arguments = ["-J", "--no-playlist", "--socket-timeout", "20", url.absoluteString]
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            var outData = Data()
            do {
                try proc.run()
                // MUST read pipe BEFORE waitUntilExit — otherwise pipe buffer fills up and process deadlocks
                outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
            } catch {
                return [DownloadFormat]()
            }

            guard !outData.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: outData) as? [String: Any],
                  let formats = json["formats"] as? [[String: Any]]
            else {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                if let errStr = String(data: errData, encoding: .utf8), !errStr.isEmpty {
                    DiagnosticsLogger.app.error("yt-dlp stderr: \(errStr)")
                }
                return [DownloadFormat]()
            }
            return Self.parseFormatsStatic(formats)
        }.value
    }

    private nonisolated static func parseFormatsStatic(_ formats: [[String: Any]]) -> [DownloadFormat] {
        var seen: Set<String> = []
        var results: [DownloadFormat] = []

        // Always add MP3 option
        results.append(DownloadFormat(
            id: "bestaudio/best",
            label: String(localized: "MP3 (audio only)"),
            isAudioOnly: true,
            fileSize: nil
        ))

        for fmt in formats {
            guard let formatId = fmt["format_id"] as? String,
                  let ext = fmt["ext"] as? String,
                  !formatId.contains("storyboard"),
                  fmt["vcodec"] as? String != "none" || formatId == "bestvideo+bestaudio"
            else { continue }

            let resolution = fmt["resolution"] as? String
            let height = fmt["height"] as? Int
            let filesize = fmt["filesize"] as? Int64 ?? fmt["filesize_approx"] as? Int64

            let label: String
            if let resolution, !resolution.isEmpty {
                label = "\(resolution) (\(ext))"
            } else if let height {
                label = "\(height)p (\(ext))"
            } else {
                continue
            }

            let key = resolution ?? "\(height ?? 0)"
            guard seen.insert(key).inserted else { continue }

            results.append(DownloadFormat(
                id: formatId,
                label: label,
                isAudioOnly: false,
                fileSize: filesize
            ))
        }

        // Sort: audio first, then highest quality first
        return results.sorted { a, _ in a.isAudioOnly }
    }

    // MARK: - Transcript (for on-device AI)

    /// Fetches the video's transcript as plain text (auto-captions included) via
    /// yt-dlp, for on-device AI features like the video summary. Returns nil when
    /// the video has no captions or yt-dlp is unavailable.
    func fetchTranscript(videoId: String) async -> String? {
        guard let ytdlpPath, let url = URL(string: "https://www.youtube.com/watch?v=\(videoId)") else { return nil }
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kaset-transcript-\(videoId)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let lang = Locale.current.language.languageCode?.identifier ?? "en"

        return await withCheckedContinuation { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ytdlpPath)
            proc.arguments = [
                "--skip-download",
                "--write-auto-subs", "--write-subs",
                "--sub-langs", "\(lang),\(lang).*,en,en.*",
                "--sub-format", "vtt",
                "--socket-timeout", "20",
                "-o", "\(tmpDir.path)/%(id)s.%(ext)s",
                url.absoluteString,
            ]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            proc.terminationHandler = { _ in
                let text = Self.transcriptText(fromDir: tmpDir)
                try? FileManager.default.removeItem(at: tmpDir)
                continuation.resume(returning: text)
            }
            do {
                try proc.run()
            } catch {
                try? FileManager.default.removeItem(at: tmpDir)
                continuation.resume(returning: nil)
            }
        }
    }

    /// Parses the first `.vtt` file in `dir` into deduplicated plain text.
    /// yt-dlp auto-captions roll and repeat lines, so consecutive duplicates and
    /// inline timing tags are stripped.
    private nonisolated static func transcriptText(fromDir dir: URL) -> String? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
              let vtt = files.first(where: { $0.pathExtension.lowercased() == "vtt" }),
              let raw = try? String(contentsOf: vtt, encoding: .utf8)
        else {
            return nil
        }

        var lines: [String] = []
        var last = ""
        for rawLine in raw.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line == "WEBVTT" || line.contains("-->")
                || line.hasPrefix("Kind:") || line.hasPrefix("Language:") || line.hasPrefix("NOTE")
            {
                continue
            }
            let clean = line
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if clean.isEmpty || clean == last {
                continue
            }
            lines.append(clean)
            last = clean
        }

        let text = lines.joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    // MARK: - Download

    enum DownloadState: Sendable {
        case idle
        case preparing
        case downloading(progress: Double, speed: String)
        case completed(filename: String)
        case failed(String)
    }

    /// Starts a download and returns a stream of state updates.
    func download(
        videoId: String,
        format: DownloadFormat,
        downloadSubtitles: Bool = false,
        onUpdate: @escaping @Sendable (DownloadState) -> Void
    ) {
        onUpdate(.preparing)
        guard let url = URL(string: "https://www.youtube.com/watch?v=\(videoId)") else {
            onUpdate(.failed(String(localized: "Invalid video URL")))
            return
        }

        guard let ytdlpPath else {
            onUpdate(.failed(String(localized: "yt-dlp not found.")))
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ytdlpPath)

        var args = [
            "--no-playlist",
            "--no-mtime",
            "-o", "\(self.downloadsDir.path)/%(title)s.%(ext)s",
        ]

        if format.isAudioOnly {
            args.append(contentsOf: [
                "-x",
                "--audio-format", "mp3",
                "--audio-quality", "0",
                "--embed-thumbnail",
            ])
        } else {
            args.append(contentsOf: ["-f", format.id])
        }

        if downloadSubtitles {
            // Real + auto-generated captions in the user's language and English,
            // written as .srt next to the file; embedded into the container for
            // video downloads (mp3 has no subtitle track).
            let lang = Locale.current.language.languageCode?.identifier ?? "en"
            args.append(contentsOf: [
                "--write-subs", "--write-auto-subs",
                "--sub-langs", "\(lang),\(lang).*,en,en.*",
                "--convert-subs", "srt",
            ])
            if !format.isAudioOnly {
                args.append("--embed-subs")
            }
        }

        args.append(url.absoluteString)
        proc.arguments = args

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        // Parse progress from yt-dlp output
        nonisolated(unsafe) var lastFilename = ""
        let onUpdateSendable = onUpdate

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = String(data: handle.availableData, encoding: .utf8) ?? ""
            guard !chunk.isEmpty else { return }

            let lines = chunk.components(separatedBy: "\n")
            for line in lines {
                if line.contains("[download] Destination:") {
                    lastFilename = line
                        .replacingOccurrences(of: "[download] Destination: ", with: "")
                        .trimmingCharacters(in: .whitespaces)
                } else if line.contains("%") {
                    let percent = Self.parsePercent(line)
                    let speed = Self.parseSpeed(line)
                    onUpdateSendable(.downloading(progress: percent, speed: speed))
                }
            }
        }

        proc.terminationHandler = { process in
            let name = lastFilename.components(separatedBy: "/").last ?? lastFilename
            if process.terminationStatus == 0 {
                onUpdateSendable(.completed(filename: name))
            } else {
                onUpdateSendable(.failed(String(localized: "Download failed. Is yt-dlp installed? Try: brew install yt-dlp")))
            }
        }

        do {
            try proc.run()
        } catch {
            onUpdate(.failed(error.localizedDescription))
        }
    }

    /// Cancels the current download by killing yt-dlp.
    func cancelDownload() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["killall", "yt-dlp"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
    }

    // MARK: - Helpers

    private nonisolated static func parsePercent(_ line: String) -> Double {
        // "[download]  45.3% of ~50MiB at ..."
        guard let range = line.range(of: #"\d+\.?\d*%"#, options: .regularExpression) else {
            return 0
        }
        let str = String(line[range]).replacingOccurrences(of: "%", with: "")
        return (Double(str) ?? 0) / 100.0
    }

    private nonisolated static func parseSpeed(_ line: String) -> String {
        // "... at 2.3MiB/s ..."
        guard let range = line.range(of: #"at\s+\S+"#, options: .regularExpression) else {
            return ""
        }
        return String(line[range])
    }
}
