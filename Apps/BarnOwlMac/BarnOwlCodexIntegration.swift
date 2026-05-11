import Foundation

struct BarnOwlCodexIntegrationSnapshot: Equatable {
    var bridgeEndpoint: String
    var bridgeStatus: String
    var bundledCLIPath: String
    var userCLIPath: String
    var userBinOnPath: Bool
    var bundledSkillPath: String
    var installedSkillPath: String
    var diagnosticsPath: String

    var lines: [String] {
        [
            "bridge_endpoint=\(bridgeEndpoint)",
            "bridge_status=\(bridgeStatus)",
            "bundled_cli=\(bundledCLIPath.isEmpty ? "missing" : "inside_app_bundle")",
            "user_cli=~/bin/barnowl",
            "user_bin_on_path=\(userBinOnPath)",
            "bundled_skill=\(bundledSkillPath.isEmpty ? "missing" : "inside_app_bundle")",
            "installed_skill=~/.codex/skills/barnowl",
            "diagnostics=Application Support/Barn Owl/Logs/barnowl.log.jsonl"
        ]
    }
}

enum BarnOwlCodexIntegration {
    static let version = "1"
    static let bridgeEndpoint = "http://127.0.0.1:\(BarnOwlControlBridge.defaultPort)"

    static var bundledCLIURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("barnowl", isDirectory: false)
    }

    static var bundledSkillURL: URL {
        (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
            .appendingPathComponent("CodexSkill", isDirectory: true)
            .appendingPathComponent("barnowl", isDirectory: true)
    }

    static var userCLIURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("barnowl", isDirectory: false)
    }

    static var installedSkillURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("barnowl", isDirectory: true)
    }

    static var diagnosticsURL: URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("Barn Owl", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("barnowl.log.jsonl", isDirectory: false)
    }

    static func snapshot(bridgeStatus: String) -> BarnOwlCodexIntegrationSnapshot {
        BarnOwlCodexIntegrationSnapshot(
            bridgeEndpoint: bridgeEndpoint,
            bridgeStatus: bridgeStatus,
            bundledCLIPath: bundledCLIURL.path,
            userCLIPath: userCLIURL.path,
            userBinOnPath: userBinOnPath(),
            bundledSkillPath: bundledSkillURL.path,
            installedSkillPath: installedSkillURL.path,
            diagnosticsPath: diagnosticsURL.path
        )
    }

    static func bridgeStatus() async -> String {
        guard let url = URL(string: "\(bridgeEndpoint)/status") else {
            return "invalid endpoint"
        }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                return "running"
            }
            return "not running"
        } catch {
            return "not running"
        }
    }

    @discardableResult
    static func installCLI(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundledCLIURL: URL = BarnOwlCodexIntegration.bundledCLIURL
    ) throws -> URL {
        let binDirectory = homeDirectory.appendingPathComponent("bin", isDirectory: true)
        let destination = binDirectory.appendingPathComponent("barnowl", isDirectory: false)
        try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: destination.path) {
            if let symlinkDestination = try? fileManager.destinationOfSymbolicLink(atPath: destination.path),
               symlinkDestination == bundledCLIURL.path {
                return destination
            }
            let backup = binDirectory.appendingPathComponent(
                "barnowl.backup.\(Int(Date().timeIntervalSince1970))",
                isDirectory: false
            )
            try? fileManager.removeItem(at: backup)
            try fileManager.moveItem(at: destination, to: backup)
        }

        try fileManager.createSymbolicLink(at: destination, withDestinationURL: bundledCLIURL)
        return destination
    }

    @discardableResult
    static func installCodexSkill(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundledSkillURL: URL = BarnOwlCodexIntegration.bundledSkillURL
    ) throws -> URL {
        let skillsDirectory = homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
        let destination = skillsDirectory.appendingPathComponent("barnowl", isDirectory: true)
        let marker = destination.appendingPathComponent(".barnowl-version", isDirectory: false)

        try fileManager.createDirectory(at: skillsDirectory, withIntermediateDirectories: true)
        removeLegacySkillBackups(in: skillsDirectory, fileManager: fileManager)
        if fileManager.fileExists(atPath: destination.path) {
            if !fileManager.fileExists(atPath: marker.path) {
                let backupDirectory = homeDirectory
                    .appendingPathComponent(".codex", isDirectory: true)
                    .appendingPathComponent("barnowl-skill-backups", isDirectory: true)
                try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
                let backup = backupDirectory.appendingPathComponent(
                    "barnowl.backup.\(Int(Date().timeIntervalSince1970))",
                    isDirectory: true
                )
                try? fileManager.removeItem(at: backup)
                try fileManager.moveItem(at: destination, to: backup)
            } else {
                try fileManager.removeItem(at: destination)
            }
        }

        try fileManager.copyItem(at: bundledSkillURL, to: destination)
        try version.data(using: .utf8)?.write(to: marker, options: .atomic)
        let script = destination
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("barnowl", isDirectory: false)
        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return destination
    }

    private static func removeLegacySkillBackups(
        in skillsDirectory: URL,
        fileManager: FileManager
    ) {
        guard let children = try? fileManager.contentsOfDirectory(
            at: skillsDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for child in children where child.lastPathComponent.hasPrefix("barnowl.backup.") {
            try? fileManager.removeItem(at: child)
        }
    }

    static func testCLI(cliURL: URL? = nil) throws -> String {
        let cli = cliURL ?? (FileManager.default.isExecutableFile(atPath: userCLIURL.path) ? userCLIURL : bundledCLIURL)
        let process = Process()
        process.executableURL = cli
        process.arguments = ["status", "--no-launch"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if process.terminationStatus == 0 {
            return output.isEmpty ? "CLI status succeeded." : output
        }
        return output.isEmpty ? "CLI status failed." : output
    }

    static func userBinOnPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let path = environment["PATH"] else { return false }
        let userBin = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("bin", isDirectory: true)
            .path
        return path.split(separator: ":").map(String.init).contains(userBin)
    }
}
