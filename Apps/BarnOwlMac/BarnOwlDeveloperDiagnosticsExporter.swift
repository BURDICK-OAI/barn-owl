import BarnOwlPersistence
import Foundation

struct BarnOwlDeveloperDiagnosticsSnapshot: Equatable {
    var generatedAt: Date
    var appVersion: String
    var appBuild: String
    var bundleIdentifier: String
    var operatingSystem: String
    var architecture: String
    var updateChannel: String
    var updateManifest: String
    var readinessLines: [String]
    var diagnosticsEntries: [DiagnosticsLogEntry]
}

enum BarnOwlDeveloperDiagnosticsExporter {
    static func defaultFileName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "BarnOwl-developer-diagnostics-\(formatter.string(from: now)).md"
    }

    @MainActor
    static func makeSnapshot(
        generatedAt: Date = Date(),
        readinessLines: [String],
        diagnosticsEntries: [DiagnosticsLogEntry],
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo
    ) -> BarnOwlDeveloperDiagnosticsSnapshot {
        BarnOwlDeveloperDiagnosticsSnapshot(
            generatedAt: generatedAt,
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            appBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            bundleIdentifier: bundle.bundleIdentifier ?? "unknown",
            operatingSystem: processInfo.operatingSystemVersionString,
            architecture: Self.machineArchitecture(),
            updateChannel: BarnOwlUpdaterSettings.updateChannelLabel,
            updateManifest: BarnOwlUpdaterSettings.resolvedManifestDisplayPath(),
            readinessLines: readinessLines.map(sanitize),
            diagnosticsEntries: diagnosticsEntries
        )
    }

    static func makeReport(_ snapshot: BarnOwlDeveloperDiagnosticsSnapshot) -> String {
        var lines: [String] = []
        lines.append("# Barn Owl Developer Diagnostics")
        lines.append("")
        lines.append("Generated: `\(iso8601String(from: snapshot.generatedAt))`")
        lines.append("")
        lines.append("## App")
        lines.append("")
        lines.append("- Bundle ID: `\(sanitize(snapshot.bundleIdentifier))`")
        lines.append("- Version: `\(sanitize(snapshot.appVersion)) (\(sanitize(snapshot.appBuild)))`")
        lines.append("- macOS: `\(sanitize(snapshot.operatingSystem))`")
        lines.append("- Architecture: `\(sanitize(snapshot.architecture))`")
        lines.append("")
        lines.append("## Updates")
        lines.append("")
        lines.append("- Channel: `\(sanitize(snapshot.updateChannel))`")
        lines.append("- Manifest: `\(sanitize(snapshot.updateManifest))`")
        lines.append("")
        lines.append("## Readiness")
        lines.append("")
        if snapshot.readinessLines.isEmpty {
            lines.append("No readiness diagnostics were available.")
        } else {
            for readinessLine in snapshot.readinessLines {
                lines.append("- `\(sanitize(readinessLine))`")
            }
        }
        lines.append("")
        lines.append("## Recent Diagnostics")
        lines.append("")
        lines.append("Messages are redacted and truncated. Raw audio, transcripts, API keys, and private paths are not included.")
        lines.append("")
        if snapshot.diagnosticsEntries.isEmpty {
            lines.append("No recent diagnostics were available.")
        } else {
            for entry in snapshot.diagnosticsEntries {
                lines.append("- `\(iso8601String(from: entry.timestamp))` `\(entry.level.rawValue)` `\(sanitize(entry.category))`")
                lines.append("  - Message: \(sanitize(entry.message))")
                if let details = entry.details?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !details.isEmpty {
                    lines.append("  - Details: omitted from export to avoid sharing meeting content. (`details_present=true`)")
                }
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func export(_ report: String, to url: URL) throws {
        let data = Data(report.utf8)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path(percentEncoded: false)
        )
    }

    static func diagnosticsLogStore() -> DiagnosticsLogStore {
        DiagnosticsLogStore(rootDirectory: defaultDiagnosticsRoot())
    }

    static func sanitize(_ text: String) -> String {
        let keyRedacted = DiagnosticsLogStore.redacted(text) ?? text
        return BarnOwlErrorFormatter.sanitizeForUserDisplay(keyRedacted)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func defaultDiagnosticsRoot() -> URL {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return root
            .appending(path: "Barn Owl", directoryHint: .isDirectory)
            .appending(path: "Logs", directoryHint: .isDirectory)
    }

    private static func machineArchitecture() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingCString: $0) ?? "unknown"
            }
        }
    }
}
