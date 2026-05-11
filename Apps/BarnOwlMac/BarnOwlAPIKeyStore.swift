import BarnOwlOpenAI
import CryptoKit
import Foundation
import LocalAuthentication
import Security

enum BarnOwlAPIKeyStoreError: Error, Equatable {
    case invalidAPIKey
    case missingApplicationSupportDirectory
    case keychainReadFailed(OSStatus)
    case keychainSaveFailed(OSStatus)
    case keychainDeleteFailed(OSStatus)
    case fileReadFailed
    case fileSaveFailed
    case fileDeleteFailed
}

enum BarnOwlAPIKeyStore {
    private static let service = "com.barnowl.mac.openai"
    private static let account = "OPENAI_API_KEY"
    private static let verifiedKeyFingerprintDefaultsKey = "BarnOwlOpenAIAPIKeyVerifiedFingerprint"
    private static let memoryCache = APIKeyMemoryCache()
    private static let dependencies = APIKeyStoreDependencyBox()

    static func makeConfiguration(allowKeychainPrompt: Bool = false) throws -> OpenAIConfiguration {
        OpenAIConfiguration(apiKey: try loadAPIKey(allowKeychainPrompt: allowKeychainPrompt))
    }

    static func hasConfiguredAPIKey() -> Bool {
        if memoryCache.hasValue {
            return true
        }

        if let environmentKey = dependencies.environment()[account]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !environmentKey.isEmpty {
            return true
        }

        if let fileKey = try? loadFileAPIKey()?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fileKey.isEmpty {
            return true
        }

        return false
    }

    static func hasVerifiedAPIKey() -> Bool {
        guard let storedFingerprint = UserDefaults.standard.string(forKey: verifiedKeyFingerprintDefaultsKey) else {
            return false
        }

        if let cachedKey = memoryCache.load()?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cachedKey.isEmpty {
            return storedFingerprint == fingerprint(for: cachedKey)
        }

        if let environmentKey = dependencies.environment()[account]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !environmentKey.isEmpty {
            return storedFingerprint == fingerprint(for: environmentKey)
        }

        guard let apiKey = try? loadFileAPIKey()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty else {
            return false
        }

        return storedFingerprint == fingerprint(for: apiKey)
    }

    static func markAPIKeyVerified(_ apiKey: String) {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(fingerprint(for: trimmedKey), forKey: verifiedKeyFingerprintDefaultsKey)
    }

    static func invalidateCachedAPIKeyAfterAuthenticationFailure() {
        memoryCache.clearAndSkipKeychainFallback()
        clearAPIKeyVerification()
    }

    static func loadAPIKey(allowKeychainPrompt: Bool = false) throws -> String {
        if let cachedKey = memoryCache.load() {
            return cachedKey
        }

        if let environmentKey = dependencies.environment()[account]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !environmentKey.isEmpty {
            memoryCache.store(environmentKey)
            return environmentKey
        }

        do {
            if let fileKey = try loadLocalFileAPIKey() {
                memoryCache.store(fileKey)
                return fileKey
            }
        } catch {
            // Fall through to keychain fallback and then the standard missing-key error.
        }

        if memoryCache.shouldAttemptNoninteractiveKeychainRead {
            do {
                if let keychainKey = try dependencies.loadKeychainAPIKey(allowsUserInteraction: false)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !keychainKey.isEmpty {
                    try? saveFileAPIKey(keychainKey)
                    memoryCache.store(keychainKey)
                    return keychainKey
                }
                memoryCache.storeKeychainFallbackMiss()
            } catch {
                // Ad-hoc local builds can lose Keychain ACL access. Keep status checks quiet, but allow
                // one later interactive read when an operation actually needs the key.
                memoryCache.storeKeychainFallbackNeedsInteraction()
            }
        }

        if allowKeychainPrompt,
           memoryCache.shouldAttemptInteractiveKeychainRead {
            memoryCache.storeInteractiveKeychainFallbackAttempt()
            do {
                if let keychainKey = try dependencies.loadKeychainAPIKey(allowsUserInteraction: true)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !keychainKey.isEmpty {
                    try? saveFileAPIKey(keychainKey)
                    memoryCache.store(keychainKey)
                    return keychainKey
                }
            } catch {
                // Fall through to environment/local-file fallback. Repeated password prompts are worse
                // than reporting the missing-key path; users can re-save the key from Settings.
            }
        }

        throw OpenAIConfigurationError.missingAPIKey
    }

    static func saveAPIKey(_ apiKey: String) throws {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw BarnOwlAPIKeyStoreError.invalidAPIKey
        }

        try saveFileAPIKey(trimmedKey)
        clearAPIKeyVerification()
        memoryCache.store(trimmedKey)
    }

    static func saveKeychainOnlyAPIKey(_ apiKey: String) throws {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw BarnOwlAPIKeyStoreError.invalidAPIKey
        }

        try dependencies.saveKeychainAPIKey(trimmedKey, allowsUserInteraction: true)
        clearAPIKeyVerification()
        memoryCache.store(trimmedKey)
    }

    static func repairSavedAPIKeyAccess() throws {
        let key = try loadAPIKey(allowKeychainPrompt: true).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw BarnOwlAPIKeyStoreError.invalidAPIKey
        }

        try saveFileAPIKey(key)
        memoryCache.store(key)
    }

    static func deleteStoredAPIKey() throws {
        try? deleteFileAPIKey()
        clearAPIKeyVerification()
        memoryCache.clear()
        try? dependencies.deleteKeychainAPIKey()
    }

    static func diagnosticLines() -> [String] {
        var lines: [String] = []
        let environmentKey = dependencies.environment()[account]?.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append("environment_configured=\(!(environmentKey?.isEmpty ?? true))")
        lines.append("memory_cache_configured=\(memoryCache.hasValue)")

        do {
            let fileURL = try localAPIKeyFileURL()
            let filePath = fileURL.path(percentEncoded: false)
            let fileExists = FileManager.default.fileExists(atPath: filePath)
            lines.append("local_file_exists=\(fileExists)")
            lines.append("local_file_location=local_user_config")

            if fileExists {
                try? normalizeLocalAPIKeyPermissions()
                let attributes = try FileManager.default.attributesOfItem(atPath: filePath)
                let byteCount = attributes[.size] as? Int ?? 0
                lines.append("local_file_readable=true")
                lines.append("local_file_nonempty=\(byteCount > 0)")
                if let permissions = try? filePermissions(at: fileURL) {
                    lines.append("local_file_permissions=\(String(permissions, radix: 8))")
                    lines.append("local_file_permissions_restricted=\(permissions == 0o600)")
                }
                if let directoryPermissions = try? filePermissions(at: fileURL.deletingLastPathComponent()) {
                    lines.append("local_directory_permissions=\(String(directoryPermissions, radix: 8))")
                    lines.append("local_directory_permissions_restricted=\(directoryPermissions == 0o700)")
                }
            }
        } catch {
            lines.append("local_file_readable=false")
        }

        lines.append("secret_storage=local_user_config")
        lines.append("keychain_default=false")
        lines.append("keychain_storage=legacy_read_only_migration")
        lines.append("keychain_fallback=user_initiated_migration")
        lines.append("keychain_reference_exists=\(dependencies.keychainContainsAPIKey())")

        lines.append("load_api_key_success=\(hasConfiguredAPIKey())")
        return lines
    }

    static func localAPIKeyFileURL() throws -> URL {
        if let overrideURL = try dependencies.localAPIKeyFileURLOverride() {
            return overrideURL
        }

        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw BarnOwlAPIKeyStoreError.missingApplicationSupportDirectory
        }

        return applicationSupport
            .appending(path: "Barn Owl", directoryHint: .isDirectory)
            .appending(path: "Secrets", directoryHint: .isDirectory)
            .appending(path: "openai-api-key", directoryHint: .notDirectory)
    }

    fileprivate static func saveKeychainAPIKey(
        _ trimmedKey: String,
        allowsUserInteraction: Bool = true
    ) throws {
        let keyData = Data(trimmedKey.utf8)
        var query = baseKeychainQuery(allowsUserInteraction: allowsUserInteraction, storage: .dataProtection)
        query[kSecValueData as String] = keyData
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                baseKeychainQuery(allowsUserInteraction: allowsUserInteraction, storage: .dataProtection) as CFDictionary,
                [kSecValueData as String: keyData] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw BarnOwlAPIKeyStoreError.keychainSaveFailed(updateStatus)
            }
            try? deleteKeychainAPIKey(storage: .legacyLogin, allowsUserInteraction: false)
            return
        }

        guard status == errSecSuccess else {
            throw BarnOwlAPIKeyStoreError.keychainSaveFailed(status)
        }
        try? deleteKeychainAPIKey(storage: .legacyLogin, allowsUserInteraction: false)
    }

    fileprivate static func deleteKeychainAPIKey() throws {
        try deleteKeychainAPIKey(storage: .dataProtection)
        try deleteKeychainAPIKey(storage: .legacyLogin)
    }

    fileprivate static func loadKeychainAPIKey(allowsUserInteraction: Bool) throws -> String? {
        if let apiKey = try copyKeychainAPIKey(
            allowsUserInteraction: allowsUserInteraction,
            storage: .dataProtection
        ) {
            return apiKey
        }

        guard allowsUserInteraction else {
            return nil
        }

        guard let legacyAPIKey = try copyKeychainAPIKey(
            allowsUserInteraction: allowsUserInteraction,
            storage: .legacyLogin
        ) else {
            return nil
        }

        try? saveKeychainAPIKey(legacyAPIKey.trimmingCharacters(in: .whitespacesAndNewlines), allowsUserInteraction: false)
        return legacyAPIKey
    }

    fileprivate static func keychainContainsAPIKeyReference() -> Bool {
        keychainContainsAPIKeyReference(storage: .dataProtection)
            || keychainContainsAPIKeyReference(storage: .legacyLogin)
    }

    private static func keychainContainsAPIKeyReference(storage: KeychainStorage) -> Bool {
        var query = baseKeychainQuery(allowsUserInteraction: false, storage: storage)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return status == errSecSuccess
    }

    private static func copyKeychainAPIKey(
        allowsUserInteraction: Bool,
        storage: KeychainStorage
    ) throws -> String? {
        var query = baseKeychainQuery(allowsUserInteraction: allowsUserInteraction, storage: storage)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw BarnOwlAPIKeyStoreError.keychainReadFailed(status)
        }

        guard let data = result as? Data,
              let apiKey = String(data: data, encoding: .utf8)
        else {
            throw BarnOwlAPIKeyStoreError.invalidAPIKey
        }

        return apiKey
    }

    private static func deleteKeychainAPIKey(
        storage: KeychainStorage,
        allowsUserInteraction: Bool = true
    ) throws {
        let status = SecItemDelete(
            baseKeychainQuery(
                allowsUserInteraction: allowsUserInteraction,
                storage: storage
            ) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BarnOwlAPIKeyStoreError.keychainDeleteFailed(status)
        }
    }

    private static func loadLocalFileAPIKey() throws -> String? {
        guard let fileKey = try loadFileAPIKey()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !fileKey.isEmpty else {
            return nil
        }

        try normalizeLocalAPIKeyPermissions()
        return fileKey
    }

    private static func loadFileAPIKey() throws -> String? {
        let url = try localAPIKeyFileURL()
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return nil
        }

        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw BarnOwlAPIKeyStoreError.fileReadFailed
        }
    }

    private static func saveFileAPIKey(_ apiKey: String) throws {
        let url = try localAPIKeyFileURL()
        let directory = url.deletingLastPathComponent()

        do {
            try ensureSecretsDirectory(at: directory)
            try apiKey.appending("\n").write(to: url, atomically: true, encoding: .utf8)
            try setPermissions(0o600, at: url)
        } catch {
            throw BarnOwlAPIKeyStoreError.fileSaveFailed
        }
    }

    private static func normalizeLocalAPIKeyPermissions() throws {
        let url = try localAPIKeyFileURL()
        try ensureSecretsDirectory(at: url.deletingLastPathComponent())
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return
        }

        do {
            try setPermissions(0o600, at: url)
        } catch {
            throw BarnOwlAPIKeyStoreError.fileSaveFailed
        }
    }

    private static func ensureSecretsDirectory(at directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try setPermissions(0o700, at: directory)
    }

    private static func setPermissions(_ permissions: Int, at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path(percentEncoded: false)
        )
    }

    private static func filePermissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return attributes[.posixPermissions] as? Int ?? 0
    }

    private static func clearAPIKeyVerification() {
        UserDefaults.standard.removeObject(forKey: verifiedKeyFingerprintDefaultsKey)
    }

    private static func fingerprint(for apiKey: String) -> String {
        SHA256.hash(data: Data(apiKey.utf8))
            .map { String(format: "%02x", Int($0)) }
            .joined()
    }

    private static func deleteFileAPIKey() throws {
        let url = try localAPIKeyFileURL()
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return
        }

        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw BarnOwlAPIKeyStoreError.fileDeleteFailed
        }
    }

    private enum KeychainStorage {
        case dataProtection
        case legacyLogin
    }

    private static func baseKeychainQuery(
        allowsUserInteraction: Bool = true,
        storage: KeychainStorage = .dataProtection
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if storage == .dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        if !allowsUserInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
            // LAContext.interactionNotAllowed should be enough, but legacy login-keychain reads can
            // still block on some local/ad-hoc installs. The raw value avoids the deprecated symbol.
            query[kSecUseAuthenticationUI as String] = "fail"
        }
        return query
    }

#if DEBUG
    static func clearMemoryCacheForTesting() {
        memoryCache.clear()
    }

    static func withTestingOverrides<T>(
        environment: [String: String]? = nil,
        localAPIKeyFileURL: URL? = nil,
        keychainReader: (@Sendable (_ allowsUserInteraction: Bool) throws -> String?)? = nil,
        keychainWriter: (@Sendable (_ apiKey: String, _ allowsUserInteraction: Bool) throws -> Void)? = nil,
        keychainDeleter: (@Sendable () throws -> Void)? = nil,
        operation: () throws -> T
    ) throws -> T {
        try dependencies.withTestingOverrides(
            environment: environment,
            localAPIKeyFileURL: localAPIKeyFileURL,
            keychainReader: keychainReader,
            keychainWriter: keychainWriter,
            keychainDeleter: keychainDeleter,
            operation: operation
        )
    }
#endif
}

private final class APIKeyMemoryCache: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    private var noninteractiveKeychainReadFinishedValue = false
    private var keychainNeedsInteractiveFallbackValue = false
    private var interactiveKeychainFallbackAttemptedValue = false

    var hasValue: Bool {
        lock.withLock { value?.isEmpty == false }
    }

    func load() -> String? {
        lock.withLock { value }
    }

    func store(_ key: String) {
        lock.withLock {
            value = key
            noninteractiveKeychainReadFinishedValue = false
            keychainNeedsInteractiveFallbackValue = false
            interactiveKeychainFallbackAttemptedValue = false
        }
    }

    func clear() {
        lock.withLock {
            value = nil
            noninteractiveKeychainReadFinishedValue = false
            keychainNeedsInteractiveFallbackValue = false
            interactiveKeychainFallbackAttemptedValue = false
        }
    }

    func clearAndSkipKeychainFallback() {
        lock.withLock {
            value = nil
            noninteractiveKeychainReadFinishedValue = true
            keychainNeedsInteractiveFallbackValue = false
            interactiveKeychainFallbackAttemptedValue = true
        }
    }

    var shouldAttemptNoninteractiveKeychainRead: Bool {
        lock.withLock { !noninteractiveKeychainReadFinishedValue }
    }

    var shouldAttemptInteractiveKeychainRead: Bool {
        lock.withLock {
            keychainNeedsInteractiveFallbackValue && !interactiveKeychainFallbackAttemptedValue
        }
    }

    func storeKeychainFallbackMiss() {
        lock.withLock {
            noninteractiveKeychainReadFinishedValue = true
            keychainNeedsInteractiveFallbackValue = false
        }
    }

    func storeKeychainFallbackNeedsInteraction() {
        lock.withLock {
            noninteractiveKeychainReadFinishedValue = true
            keychainNeedsInteractiveFallbackValue = true
        }
    }

    func storeInteractiveKeychainFallbackAttempt() {
        lock.withLock {
            interactiveKeychainFallbackAttemptedValue = true
        }
    }
}

private struct APIKeyStoreDependencies {
    var environment: @Sendable () -> [String: String]
    var localAPIKeyFileURLOverride: (@Sendable () throws -> URL?)?
    var keychainReader: @Sendable (_ allowsUserInteraction: Bool) throws -> String?
    var keychainPresence: @Sendable () -> Bool
    var keychainWriter: @Sendable (_ apiKey: String, _ allowsUserInteraction: Bool) throws -> Void
    var keychainDeleter: @Sendable () throws -> Void

    static let live = APIKeyStoreDependencies(
        environment: { ProcessInfo.processInfo.environment },
        localAPIKeyFileURLOverride: nil,
        keychainReader: BarnOwlAPIKeyStore.loadKeychainAPIKey,
        keychainPresence: BarnOwlAPIKeyStore.keychainContainsAPIKeyReference,
        keychainWriter: BarnOwlAPIKeyStore.saveKeychainAPIKey,
        keychainDeleter: BarnOwlAPIKeyStore.deleteKeychainAPIKey
    )
}

private final class APIKeyStoreDependencyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var dependencies = APIKeyStoreDependencies.live

    func environment() -> [String: String] {
        lock.withLock {
            dependencies.environment()
        }
    }

    func localAPIKeyFileURLOverride() throws -> URL? {
        let provider = lock.withLock {
            dependencies.localAPIKeyFileURLOverride
        }
        return try provider?()
    }

    func loadKeychainAPIKey(allowsUserInteraction: Bool) throws -> String? {
        let reader = lock.withLock {
            dependencies.keychainReader
        }
        return try reader(allowsUserInteraction)
    }

    func keychainContainsAPIKey() -> Bool {
        let presence = lock.withLock {
            dependencies.keychainPresence
        }
        return presence()
    }

    func saveKeychainAPIKey(_ apiKey: String, allowsUserInteraction: Bool) throws {
        let writer = lock.withLock {
            dependencies.keychainWriter
        }
        try writer(apiKey, allowsUserInteraction)
    }

    func deleteKeychainAPIKey() throws {
        let deleter = lock.withLock {
            dependencies.keychainDeleter
        }
        try deleter()
    }

#if DEBUG
    func withTestingOverrides<T>(
        environment: [String: String]?,
        localAPIKeyFileURL: URL?,
        keychainReader: (@Sendable (_ allowsUserInteraction: Bool) throws -> String?)?,
        keychainWriter: (@Sendable (_ apiKey: String, _ allowsUserInteraction: Bool) throws -> Void)?,
        keychainDeleter: (@Sendable () throws -> Void)?,
        operation: () throws -> T
    ) throws -> T {
        lock.lock()
        let previous = dependencies
        let environmentProvider: @Sendable () -> [String: String]
        if let environment {
            environmentProvider = { @Sendable in environment }
        } else {
            environmentProvider = previous.environment
        }

        let localAPIKeyFileURLProvider: (@Sendable () throws -> URL?)?
        if let localAPIKeyFileURL {
            localAPIKeyFileURLProvider = { @Sendable () throws -> URL? in localAPIKeyFileURL }
        } else {
            localAPIKeyFileURLProvider = previous.localAPIKeyFileURLOverride
        }

        dependencies = APIKeyStoreDependencies(
            environment: environmentProvider,
            localAPIKeyFileURLOverride: localAPIKeyFileURLProvider,
            keychainReader: keychainReader ?? previous.keychainReader,
            keychainPresence: keychainReader.map { reader in
                { @Sendable in
                    guard let key = try? reader(false)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                        return false
                    }
                    return !key.isEmpty
                }
            } ?? previous.keychainPresence,
            keychainWriter: keychainWriter ?? previous.keychainWriter,
            keychainDeleter: keychainDeleter ?? previous.keychainDeleter
        )
        lock.unlock()

        defer {
            lock.lock()
            dependencies = previous
            lock.unlock()
        }
        return try operation()
    }
#endif
}
