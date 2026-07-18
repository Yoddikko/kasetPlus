import Foundation
import OSLog

/// Collects environment details (app/OS/hardware) and recent logs to attach to a
/// bug report, so users don't have to gather them by hand.
enum DiagnosticsReport {
    struct Environment {
        let appVersion: String
        let buildNumber: String
        let macOSVersion: String
        let hardwareModel: String
        let cpu: String
        let memoryGB: Int
        let architecture: String
    }

    static func environment() -> Environment {
        let info = Bundle.main.infoDictionary
        let appVersion = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"

        let os = ProcessInfo.processInfo.operatingSystemVersion
        let macOS = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"

        let memoryGB = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())

        return Environment(
            appVersion: appVersion,
            buildNumber: build,
            macOSVersion: macOS,
            hardwareModel: Self.sysctl("hw.model") ?? "unknown",
            cpu: Self.sysctl("machdep.cpu.brand_string") ?? "unknown",
            memoryGB: memoryGB,
            architecture: Self.sysctl("hw.machine") ?? "unknown"
        )
    }

    /// A Markdown block ready to append to an issue body.
    static func markdown(includingLogs includeLogs: Bool) -> String {
        let env = Self.environment()
        var lines = [
            "",
            "---",
            "<details><summary>Diagnostics (auto-collected)</summary>",
            "",
            "| | |",
            "|---|---|",
            "| KasetPlus | \(env.appVersion) (build \(env.buildNumber)) |",
            "| macOS | \(env.macOSVersion) |",
            "| Model | \(env.hardwareModel) |",
            "| Chip | \(env.cpu) |",
            "| Memory | \(env.memoryGB) GB |",
            "| Architecture | \(env.architecture) |",
        ]
        if includeLogs {
            let logs = Self.recentLogs()
            if !logs.isEmpty {
                lines.append("")
                lines.append("**Recent logs**")
                lines.append("```")
                lines.append(logs)
                lines.append("```")
            }
        }
        lines.append("")
        lines.append("</details>")
        return lines.joined(separator: "\n")
    }

    // MARK: - Logs

    /// The tail of the app's recent os_log entries (best-effort; empty if the
    /// log store can't be read). Redacts nothing beyond OSLog's own privacy —
    /// the compose screen shows this so the user can review before sending.
    static func recentLogs(limit: Int = 200) -> String {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let since = store.position(date: Date().addingTimeInterval(-600))
            let entries = try store.getEntries(at: since)
            let lines = entries
                .compactMap { $0 as? OSLogEntryLog }
                .filter { $0.subsystem.contains("Kaset") }
                .suffix(limit)
                .map { "[\($0.category)] \($0.composedMessage)" }
            return lines.joined(separator: "\n")
        } catch {
            return ""
        }
    }

    // MARK: - sysctl

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
