import AppKit
import CryptoKit
import Foundation
import Security

struct BarnOwlUpdateManifest: Decodable, Equatable {
    var version: String
    var build: String
    var archiveURL: String
    var sha256: String?
    var notes: String?

    private enum CodingKeys: String, CodingKey {
        case version
        case build
        case archiveURL = "archive_url"
        case sha256
        case notes
    }
}

enum BarnOwlUpdateResult: Equatable {
    case upToDate(version: String, build: String)
    case installing(version: String, build: String)
}

struct BarnOwlUpdateSignatureSummary: Equatable {
    var hasValidSignature: Bool
    var isAdHoc: Bool
    var teamIdentifier: String?
    var authorityNames: [String] = []
}

struct BarnOwlAvailableUpdate: Equatable {
    var version: String
    var build: String
    var notes: String?
}

enum BarnOwlUpdateAvailability: Equatable {
    case unknown
    case checking
    case available(BarnOwlAvailableUpdate)
    case upToDate(version: String, build: String)
    case unavailable(String)

    var hasInstallableUpdate: Bool {
        if case .available = self {
            return true
        }
        return false
    }

    var buttonTitle: String {
        switch self {
        case .unknown:
            "Update Unavailable"
        case .checking:
            "Checking..."
        case .available:
            "Update Available"
        case .upToDate:
            "Up to Date"
        case .unavailable:
            "Update Unavailable"
        }
    }

    var statusText: String {
        switch self {
        case .unknown:
            "Update status unknown."
        case .checking:
            "Checking for updates..."
        case .available(let update):
            "Barn Owl \(update.version) (\(update.build)) is available."
        case .upToDate(let version, let build):
            "Barn Owl is up to date: \(version) (\(build))."
        case .unavailable(let message):
            message
        }
    }
}

enum BarnOwlUpdateError: LocalizedError, Equatable {
    case noManifestConfigured
    case invalidManifestURL(String)
    case invalidArchiveURL(String)
    case insecureManifestURL
    case insecureArchiveURL
    case missingArchiveChecksum
    case updateIsNotBarnOwl
    case archiveMissingAppBundle
    case archiveChecksumMismatch
    case untrustedArchiveSignature
    case updateTeamMismatch
    case installerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noManifestConfigured:
            "No update manifest is configured. Add one in Settings."
        case .invalidManifestURL(let value):
            "The update manifest URL is invalid: \(value)"
        case .invalidArchiveURL(let value):
            "The update archive URL is invalid: \(value)"
        case .insecureManifestURL:
            "Remote update manifests must use HTTPS."
        case .insecureArchiveURL:
            "Remote update archives must use HTTPS."
        case .missingArchiveChecksum:
            "The update manifest is missing the archive checksum."
        case .updateIsNotBarnOwl:
            "The downloaded app is not a Barn Owl update."
        case .archiveMissingAppBundle:
            "The update archive did not contain a .app bundle."
        case .archiveChecksumMismatch:
            "The update archive checksum did not match the manifest."
        case .untrustedArchiveSignature:
            "The update archive signature is invalid."
        case .updateTeamMismatch:
            "The update is signed by a different Apple developer team than this Barn Owl app."
        case .installerFailed(let message):
            "The update installer failed: \(message)"
        }
    }
}

@MainActor
enum BarnOwlUpdaterSettings {
    static let manifestURLDefaultsKey = "BarnOwlUpdateManifestURL"
    static let defaultGitManifestURLString =
        "https://raw.githubusercontent.com/BURDICK-OAI/barn-owl/main/Updates/BarnOwl/BarnOwl-update-manifest.json"

    static var manifestURLString: String {
        get {
            UserDefaults.standard.string(forKey: manifestURLDefaultsKey) ?? ""
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                UserDefaults.standard.removeObject(forKey: manifestURLDefaultsKey)
            } else {
                UserDefaults.standard.set(trimmed, forKey: manifestURLDefaultsKey)
            }
        }
    }

    static func defaultManifestURL() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Barn Owl", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("update-manifest.json", isDirectory: false)
    }

    static func resolvedManifestURL() throws -> URL {
        if !manifestURLString.isEmpty {
            guard let url = BarnOwlUpdater.url(from: manifestURLString) else {
                throw BarnOwlUpdateError.invalidManifestURL(manifestURLString)
            }
            return url
        }

        let localManifest = try defaultManifestURL()
        if FileManager.default.fileExists(atPath: localManifest.path(percentEncoded: false)) {
            return localManifest
        }

        guard let defaultURL = BarnOwlUpdater.url(from: defaultGitManifestURLString) else {
            throw BarnOwlUpdateError.invalidManifestURL(defaultGitManifestURLString)
        }
        return defaultURL
    }

    static func resolvedManifestDisplayPath() -> String {
        if !manifestURLString.isEmpty {
            return manifestURLString
        }
        if let localManifest = try? defaultManifestURL(),
           FileManager.default.fileExists(atPath: localManifest.path(percentEncoded: false)) {
            return localManifest.path(percentEncoded: false)
        }
        return defaultGitManifestURLString
    }

    static var updateChannelLabel: String {
        if !manifestURLString.isEmpty {
            return "Custom update feed"
        }
        if let localManifest = try? defaultManifestURL(),
           FileManager.default.fileExists(atPath: localManifest.path(percentEncoded: false)) {
            return "Local development manifest"
        }
        return "GitHub update feed"
    }
}

@MainActor
enum BarnOwlUpdater {
    private static let expectedBundleIdentifier = "com.barnowl.mac"
    private static let adHocSignatureFlag: UInt32 = 0x0002

    static func checkLatestAvailability() async -> BarnOwlUpdateAvailability {
        do {
            let manifestURL = try BarnOwlUpdaterSettings.resolvedManifestURL()
            let manifest = try await loadManifest(from: manifestURL)
            if manifestIsNewerThanCurrent(manifest) {
                return .available(.init(
                    version: manifest.version,
                    build: manifest.build,
                    notes: manifest.notes
                ))
            }
            return .upToDate(version: manifest.version, build: manifest.build)
        } catch {
            return .unavailable(BarnOwlErrorFormatter.message(for: error))
        }
    }

    static func checkAndInstallLatest() async throws -> BarnOwlUpdateResult {
        let manifestURL = try BarnOwlUpdaterSettings.resolvedManifestURL()
        let manifest = try await loadManifest(from: manifestURL)

        guard manifestIsNewerThanCurrent(manifest) else {
            return .upToDate(version: manifest.version, build: manifest.build)
        }

        guard let archiveURL = url(from: manifest.archiveURL, relativeTo: manifestURL) else {
            throw BarnOwlUpdateError.invalidArchiveURL(manifest.archiveURL)
        }
        try validateRemoteURL(archiveURL, insecureError: .insecureArchiveURL)
        if !archiveURL.isFileURL,
           (manifest.sha256 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw BarnOwlUpdateError.missingArchiveChecksum
        }

        let workingDirectory = try makeWorkingDirectory()
        let archive = try await downloadArchive(from: archiveURL, into: workingDirectory)
        try verifyChecksumIfNeeded(for: archive, expectedSHA256: manifest.sha256)
        let appBundle = try prepareAppBundle(from: archive, in: workingDirectory)
        try validateBarnOwlBundle(appBundle)
        try validateCodeSignature(
            appBundle,
            requiresTrustedSignature: false,
            expectedTeamIdentifier: nil
        )
        try launchInstaller(for: appBundle)
        return .installing(version: manifest.version, build: manifest.build)
    }

    static func url(from value: String, relativeTo baseURL: URL? = nil) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        if let baseURL {
            return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
        }
        return URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath)
    }

    private static func loadManifest(from url: URL) async throws -> BarnOwlUpdateManifest {
        try validateRemoteURL(url, insecureError: .insecureManifestURL)
        let data: Data
        if url.isFileURL {
            data = try Data(contentsOf: url)
        } else {
            data = try await URLSession.shared.data(from: url).0
        }
        return try JSONDecoder().decode(BarnOwlUpdateManifest.self, from: data)
    }

    private static func validateRemoteURL(_ url: URL, insecureError: BarnOwlUpdateError) throws {
        guard !url.isFileURL else { return }
        guard url.scheme?.lowercased() == "https" else {
            throw insecureError
        }
    }

    private static func manifestIsNewerThanCurrent(_ manifest: BarnOwlUpdateManifest) -> Bool {
        let currentBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        if let manifestBuild = Int(manifest.build),
           let currentBuildNumber = Int(currentBuild) {
            return manifestBuild > currentBuildNumber
        }

        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return manifest.version.compare(currentVersion, options: .numeric) == .orderedDescending
    }

    private static func makeWorkingDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BarnOwlUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func downloadArchive(from url: URL, into workingDirectory: URL) async throws -> URL {
        if url.isFileURL {
            return url
        }

        let (temporaryURL, _) = try await URLSession.shared.download(from: url)
        let destination = workingDirectory.appendingPathComponent(url.lastPathComponent.isEmpty ? "BarnOwlUpdate.zip" : url.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    private static func verifyChecksumIfNeeded(for archive: URL, expectedSHA256: String?) throws {
        guard let expectedSHA256,
              !expectedSHA256.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        let data = try Data(contentsOf: archive)
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard digest.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
            throw BarnOwlUpdateError.archiveChecksumMismatch
        }
    }

    private static func prepareAppBundle(from archive: URL, in workingDirectory: URL) throws -> URL {
        if archive.pathExtension == "app" {
            return archive
        }

        let expandedDirectory = workingDirectory.appendingPathComponent("expanded", isDirectory: true)
        try FileManager.default.createDirectory(at: expandedDirectory, withIntermediateDirectories: true)
        try runProcess("/usr/bin/ditto", arguments: ["-x", "-k", archive.path(percentEncoded: false), expandedDirectory.path(percentEncoded: false)])

        guard let enumerator = FileManager.default.enumerator(
            at: expandedDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw BarnOwlUpdateError.archiveMissingAppBundle
        }

        for case let candidate as URL in enumerator where candidate.pathExtension == "app" {
            return candidate
        }
        throw BarnOwlUpdateError.archiveMissingAppBundle
    }

    private static func validateBarnOwlBundle(_ appBundle: URL) throws {
        guard let bundle = Bundle(url: appBundle),
              bundle.bundleIdentifier == expectedBundleIdentifier
        else {
            throw BarnOwlUpdateError.updateIsNotBarnOwl
        }
    }

    nonisolated static func validateSignaturePolicy(
        _ summary: BarnOwlUpdateSignatureSummary,
        requiresTrustedSignature: Bool,
        expectedTeamIdentifier: String? = nil
    ) throws {
        guard summary.hasValidSignature else {
            throw BarnOwlUpdateError.untrustedArchiveSignature
        }

        guard requiresTrustedSignature else {
            return
        }

        let teamIdentifier = summary.teamIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard summary.isAdHoc == false,
              let teamIdentifier,
              !teamIdentifier.isEmpty,
              summary.authorityNames.contains(where: isDeveloperIDApplicationAuthority)
        else {
            throw BarnOwlUpdateError.untrustedArchiveSignature
        }

        if let expectedTeamIdentifier = expectedTeamIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !expectedTeamIdentifier.isEmpty,
           teamIdentifier != expectedTeamIdentifier {
            throw BarnOwlUpdateError.updateTeamMismatch
        }
    }

    private static func validateCodeSignature(
        _ appBundle: URL,
        requiresTrustedSignature: Bool,
        expectedTeamIdentifier: String?
    ) throws {
        let summary = try codeSignatureSummary(for: appBundle)
        try validateSignaturePolicy(
            summary,
            requiresTrustedSignature: requiresTrustedSignature,
            expectedTeamIdentifier: expectedTeamIdentifier
        )
    }

    private static func codeSignatureSummary(for appBundle: URL) throws -> BarnOwlUpdateSignatureSummary {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(appBundle as CFURL, SecCSFlags(), &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            throw BarnOwlUpdateError.untrustedArchiveSignature
        }

        let validationFlags = SecCSFlags(
            rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate
        )
        let validityStatus = SecStaticCodeCheckValidity(staticCode, validationFlags, nil)
        guard validityStatus == errSecSuccess else {
            return BarnOwlUpdateSignatureSummary(
                hasValidSignature: false,
                isAdHoc: true,
                teamIdentifier: nil,
                authorityNames: []
            )
        }

        var signingInformation: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        )
        guard infoStatus == errSecSuccess, let signingInformation else {
            throw BarnOwlUpdateError.untrustedArchiveSignature
        }

        let dictionary = signingInformation as NSDictionary
        let flags = (dictionary[kSecCodeInfoFlags] as? NSNumber)?.uint32Value ?? 0
        let teamIdentifier = dictionary[kSecCodeInfoTeamIdentifier] as? String
        let authorityNames = (dictionary[kSecCodeInfoCertificates] as? [SecCertificate] ?? [])
            .compactMap { SecCertificateCopySubjectSummary($0) as String? }
        return BarnOwlUpdateSignatureSummary(
            hasValidSignature: true,
            isAdHoc: (flags & adHocSignatureFlag) != 0,
            teamIdentifier: teamIdentifier,
            authorityNames: authorityNames
        )
    }

    private static func currentTeamIdentifier() -> String? {
        try? codeSignatureSummary(for: Bundle.main.bundleURL).teamIdentifier
    }

    private nonisolated static func isDeveloperIDApplicationAuthority(_ authority: String) -> Bool {
        authority.hasPrefix("Developer ID Application:")
    }

    private static func launchInstaller(for appBundle: URL) throws {
        let destination = URL(fileURLWithPath: "/Applications/Barn Owl.app", isDirectory: true)
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("install-barn-owl-\(UUID().uuidString).zsh")
        let backup = FileManager.default.temporaryDirectory
            .appendingPathComponent("Barn Owl Backup \(UUID().uuidString).app", isDirectory: true)
        let script = """
        #!/bin/zsh
        set -euo pipefail
        /bin/sleep 0.8
        source_app=\(shellQuote(appBundle.path(percentEncoded: false)))
        destination_app=\(shellQuote(destination.path(percentEncoded: false)))
        backup_app=\(shellQuote(backup.path(percentEncoded: false)))

        if [[ -d "$destination_app" ]]; then
          /bin/mv "$destination_app" "$backup_app"
        fi

        if /usr/bin/ditto "$source_app" "$destination_app"; then
          /bin/rm -rf "$backup_app"
        else
          install_status=$?
          /bin/rm -rf "$destination_app"
          if [[ -d "$backup_app" ]]; then
            /bin/mv "$backup_app" "$destination_app"
          fi
          exit "$install_status"
        fi

        /usr/bin/open \(shellQuote(destination.path(percentEncoded: false)))
        /bin/rm -f \(shellQuote(scriptURL.path(percentEncoded: false)))
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path(percentEncoded: false))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptURL.path(percentEncoded: false)]
        try process.run()
        NSApp.terminate(nil)
    }

    private static func runProcess(_ executablePath: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8) ?? "exit \(process.terminationStatus)"
            throw BarnOwlUpdateError.installerFailed(message)
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
