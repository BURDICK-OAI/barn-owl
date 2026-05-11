@testable import BarnOwl
import BarnOwlCore
import BarnOwlOpenAI
import Foundation
import Testing

@Suite(.serialized)
struct BarnOwlAPIKeyStoreTests {
    @Test
    func saveAPIKeyWritesKeychainAndDeletesLegacyLocalFallback() throws {
        try withTemporaryAPIKeyFile { fileURL in
            let writer = KeychainWriterSpy()
            try writeAPIKey("sk-old-local\n", to: fileURL)

            try BarnOwlAPIKeyStore.withTestingOverrides(
                environment: [:],
                localAPIKeyFileURL: fileURL,
                keychainReader: { _ in nil },
                keychainWriter: { apiKey, allowsUserInteraction in
                    writer.write(apiKey, allowsUserInteraction: allowsUserInteraction)
                }
            ) {
                BarnOwlAPIKeyStore.clearMemoryCacheForTesting()

                try BarnOwlAPIKeyStore.saveAPIKey("  sk-local  \n")

                #expect(writer.values == ["sk-local"])
                #expect(writer.interactionFlags == [true])
                #expect(!FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))
            }
        }
    }

    @Test
    func savedKeyIsNotVerifiedUntilOpenAITestPasses() throws {
        try withTemporaryAPIKeyFile { fileURL in
            try BarnOwlAPIKeyStore.withTestingOverrides(
                environment: [:],
                localAPIKeyFileURL: fileURL,
                keychainReader: { _ in "sk-saved" },
                keychainWriter: { _, _ in }
            ) {
                BarnOwlAPIKeyStore.clearMemoryCacheForTesting()

                try BarnOwlAPIKeyStore.saveAPIKey("sk-saved")

                #expect(!BarnOwlAPIKeyStore.hasVerifiedAPIKey())

                BarnOwlAPIKeyStore.markAPIKeyVerified("sk-saved")
                #expect(BarnOwlAPIKeyStore.hasVerifiedAPIKey())

                try BarnOwlAPIKeyStore.saveAPIKey("sk-replaced")
                #expect(!BarnOwlAPIKeyStore.hasVerifiedAPIKey())
            }
        }
    }

    @Test
    func keychainIsPreferredOverEnvironmentAndLocalFile() throws {
        try withTemporaryAPIKeyFile { fileURL in
            let spy = KeychainReaderSpy(result: "sk-keychain")
            try writeAPIKey("sk-local\n", to: fileURL)

            try BarnOwlAPIKeyStore.withTestingOverrides(
                environment: ["OPENAI_API_KEY": "sk-environment"],
                localAPIKeyFileURL: fileURL,
                keychainReader: { allowsUserInteraction in
                    try spy.read(allowsUserInteraction: allowsUserInteraction)
                }
            ) {
                BarnOwlAPIKeyStore.clearMemoryCacheForTesting()

                let loadedKey = try BarnOwlAPIKeyStore.loadAPIKey()
                #expect(loadedKey == "sk-keychain")
                #expect(spy.calls == [false])
            }
        }
    }

    @Test
    func environmentIsFallbackAfterKeychainMiss() throws {
        try withTemporaryAPIKeyFile { fileURL in
            let spy = KeychainReaderSpy(result: nil)

            try BarnOwlAPIKeyStore.withTestingOverrides(
                environment: ["OPENAI_API_KEY": "sk-environment"],
                localAPIKeyFileURL: fileURL,
                keychainReader: { allowsUserInteraction in
                    try spy.read(allowsUserInteraction: allowsUserInteraction)
                }
            ) {
                BarnOwlAPIKeyStore.clearMemoryCacheForTesting()

                let loadedKey = try BarnOwlAPIKeyStore.loadAPIKey()

                #expect(loadedKey == "sk-environment")
                #expect(spy.calls == [false])
            }
        }
    }

    @Test
    func localSecretFileIsMigratedToKeychainAndDeletedAfterSuccessfulMigration() throws {
        try withTemporaryAPIKeyFile { fileURL in
            let spy = KeychainReaderSpy(result: nil)
            let writer = KeychainWriterSpy()
            try writeAPIKey("sk-local\n", to: fileURL)

            try BarnOwlAPIKeyStore.withTestingOverrides(
                environment: [:],
                localAPIKeyFileURL: fileURL,
                keychainReader: { allowsUserInteraction in
                    try spy.read(allowsUserInteraction: allowsUserInteraction)
                },
                keychainWriter: { apiKey, allowsUserInteraction in
                    writer.write(apiKey, allowsUserInteraction: allowsUserInteraction)
                }
            ) {
                BarnOwlAPIKeyStore.clearMemoryCacheForTesting()

                let loadedKey = try BarnOwlAPIKeyStore.loadAPIKey()
                #expect(loadedKey == "sk-local")
                #expect(writer.values == ["sk-local"])
                #expect(writer.interactionFlags == [false])
                #expect(!FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))

                let cachedKey = try BarnOwlAPIKeyStore.loadAPIKey()
                #expect(cachedKey == "sk-local")
                #expect(BarnOwlAPIKeyStore.hasConfiguredAPIKey())
                #expect(spy.calls == [false])
            }
        }
    }

    @Test
    func missingPersistentStoresAreCachedToAvoidRepeatedKeychainReads() throws {
        try withTemporaryAPIKeyFile { fileURL in
            let spy = KeychainReaderSpy(result: nil)

            try BarnOwlAPIKeyStore.withTestingOverrides(
                environment: [:],
                localAPIKeyFileURL: fileURL,
                keychainReader: { allowsUserInteraction in
                    try spy.read(allowsUserInteraction: allowsUserInteraction)
                }
            ) {
                BarnOwlAPIKeyStore.clearMemoryCacheForTesting()

                #expect(throws: OpenAIConfigurationError.missingAPIKey) {
                    try BarnOwlAPIKeyStore.loadAPIKey()
                }
                #expect(throws: OpenAIConfigurationError.missingAPIKey) {
                    try BarnOwlAPIKeyStore.loadAPIKey()
                }
                #expect(spy.calls == [false])
            }
        }
    }

    @Test
    func statusChecksUseNonInteractiveKeychainFallbackOnce() throws {
        try withTemporaryAPIKeyFile { fileURL in
            let spy = KeychainReaderSpy(result: "sk-keychain")

            try BarnOwlAPIKeyStore.withTestingOverrides(
                environment: [:],
                localAPIKeyFileURL: fileURL,
                keychainReader: { allowsUserInteraction in
                    try spy.read(allowsUserInteraction: allowsUserInteraction)
                }
            ) {
                BarnOwlAPIKeyStore.clearMemoryCacheForTesting()

                #expect(BarnOwlAPIKeyStore.hasConfiguredAPIKey())
                let diagnostics = BarnOwlAPIKeyStore.diagnosticLines()

                #expect(spy.calls == [false])
                #expect(diagnostics.contains("keychain_default=true"))
                #expect(diagnostics.contains("keychain_storage=data_protection"))
                #expect(diagnostics.contains("keychain_fallback=legacy_login_keychain_migration"))
                #expect(diagnostics.contains("load_api_key_success=true"))
            }
        }
    }

    @Test
    func statusCheckDoesNotPromptWhenKeychainNeedsInteraction() throws {
        try withTemporaryAPIKeyFile { fileURL in
            let spy = KeychainReaderSpy(result: nil, noninteractiveError: BarnOwlAPIKeyStoreTestError.needsInteraction)

            try BarnOwlAPIKeyStore.withTestingOverrides(
                environment: [:],
                localAPIKeyFileURL: fileURL,
                keychainReader: { allowsUserInteraction in
                    try spy.read(allowsUserInteraction: allowsUserInteraction)
                }
            ) {
                BarnOwlAPIKeyStore.clearMemoryCacheForTesting()

                #expect(!BarnOwlAPIKeyStore.hasConfiguredAPIKey())

                #expect(spy.calls == [false])
            }
        }
    }

    @Test
    func keychainPromptFallbackIsAttemptedOnlyOnceAndCachedOnSuccess() throws {
        try withTemporaryAPIKeyFile { fileURL in
            let spy = KeychainReaderSpy(
                result: "sk-keychain",
                noninteractiveError: BarnOwlAPIKeyStoreTestError.needsInteraction
            )

            try BarnOwlAPIKeyStore.withTestingOverrides(
                environment: [:],
                localAPIKeyFileURL: fileURL,
                keychainReader: { allowsUserInteraction in
                    try spy.read(allowsUserInteraction: allowsUserInteraction)
                }
            ) {
                BarnOwlAPIKeyStore.clearMemoryCacheForTesting()

                let configuration = try BarnOwlAPIKeyStore.makeConfiguration()
                let cachedConfiguration = try BarnOwlAPIKeyStore.makeConfiguration()

                #expect(configuration.apiKey == "sk-keychain")
                #expect(cachedConfiguration.apiKey == "sk-keychain")
                #expect(spy.calls == [false, true])
            }
        }
    }

    @Test
    func deniedKeychainPromptIsNotRepeatedInSameProcess() throws {
        try withTemporaryAPIKeyFile { fileURL in
            let spy = KeychainReaderSpy(
                result: nil,
                noninteractiveError: BarnOwlAPIKeyStoreTestError.needsInteraction
            )

            try BarnOwlAPIKeyStore.withTestingOverrides(
                environment: [:],
                localAPIKeyFileURL: fileURL,
                keychainReader: { allowsUserInteraction in
                    try spy.read(allowsUserInteraction: allowsUserInteraction)
                }
            ) {
                BarnOwlAPIKeyStore.clearMemoryCacheForTesting()

                #expect(throws: OpenAIConfigurationError.missingAPIKey) {
                    try BarnOwlAPIKeyStore.makeConfiguration()
                }
                #expect(throws: OpenAIConfigurationError.missingAPIKey) {
                    try BarnOwlAPIKeyStore.makeConfiguration()
                }

                #expect(spy.calls == [false, true])
            }
        }
    }

    @Test
    func repairingKeychainAccessUsesUserInitiatedReadAndReSavesCurrentKey() throws {
        try withTemporaryAPIKeyFile { fileURL in
            let reader = KeychainReaderSpy(
                result: "sk-keychain",
                noninteractiveError: BarnOwlAPIKeyStoreTestError.needsInteraction
            )
            let writer = KeychainWriterSpy()

            try BarnOwlAPIKeyStore.withTestingOverrides(
                environment: [:],
                localAPIKeyFileURL: fileURL,
                keychainReader: { allowsUserInteraction in
                    try reader.read(allowsUserInteraction: allowsUserInteraction)
                },
                keychainWriter: { apiKey, allowsUserInteraction in
                    writer.write(apiKey, allowsUserInteraction: allowsUserInteraction)
                }
            ) {
                BarnOwlAPIKeyStore.clearMemoryCacheForTesting()

                try BarnOwlAPIKeyStore.repairSavedAPIKeyAccess()

                #expect(reader.calls == [false, true])
                #expect(writer.values == ["sk-keychain"])
                #expect(writer.interactionFlags == [true])
            }
        }
    }

    @Test
    func repairingKeychainAccessDoesNotPromptAgainWhenKeyIsCached() throws {
        try withTemporaryAPIKeyFile { fileURL in
            let reader = KeychainReaderSpy(result: "sk-keychain")
            let writer = KeychainWriterSpy()

            try BarnOwlAPIKeyStore.withTestingOverrides(
                environment: [:],
                localAPIKeyFileURL: fileURL,
                keychainReader: { allowsUserInteraction in
                    try reader.read(allowsUserInteraction: allowsUserInteraction)
                },
                keychainWriter: { apiKey, allowsUserInteraction in
                    writer.write(apiKey, allowsUserInteraction: allowsUserInteraction)
                }
            ) {
                BarnOwlAPIKeyStore.clearMemoryCacheForTesting()

                let loadedKey = try BarnOwlAPIKeyStore.loadAPIKey()
                try BarnOwlAPIKeyStore.repairSavedAPIKeyAccess()

                #expect(loadedKey == "sk-keychain")
                #expect(reader.calls == [false])
                #expect(writer.values == ["sk-keychain"])
                #expect(writer.interactionFlags == [true])
            }
        }
    }

    @Test
    func keychainLoadUsesNonInteractiveReadWithoutBackfillingLocalSecret() throws {
        try withTemporaryAPIKeyFile { fileURL in
            let spy = KeychainReaderSpy(result: "sk-keychain")

            try BarnOwlAPIKeyStore.withTestingOverrides(
                environment: [:],
                localAPIKeyFileURL: fileURL,
                keychainReader: { allowsUserInteraction in
                    try spy.read(allowsUserInteraction: allowsUserInteraction)
                }
            ) {
                BarnOwlAPIKeyStore.clearMemoryCacheForTesting()

                let loadedKey = try BarnOwlAPIKeyStore.loadAPIKey()

                #expect(loadedKey == "sk-keychain")
                #expect(spy.calls == [false])
                #expect(!FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))
            }
        }
    }

    @Test
    func diagnosticLinesReportLocalSecretReadinessWithoutReadingSecretValue() throws {
        try withTemporaryAPIKeyFile { fileURL in
            try writeAPIKey("sk-diagnostic\n", to: fileURL)

            try BarnOwlAPIKeyStore.withTestingOverrides(
                environment: [:],
                localAPIKeyFileURL: fileURL,
                keychainReader: { _ in nil },
                keychainWriter: { _, _ in }
            ) {
                BarnOwlAPIKeyStore.clearMemoryCacheForTesting()

                let diagnostics = BarnOwlAPIKeyStore.diagnosticLines()

                #expect(diagnostics.contains("environment_configured=false"))
                #expect(diagnostics.contains("local_file_exists=true"))
                #expect(diagnostics.contains("local_file_readable=true"))
                #expect(diagnostics.contains("local_file_nonempty=true"))
                #expect(diagnostics.contains("local_file_permissions_restricted=true"))
                #expect(diagnostics.contains("local_directory_permissions_restricted=true"))
                #expect(!diagnostics.contains { $0.contains("sk-diagnostic") })
            }
        }
    }

    @Test
    func authenticationFailureInvalidatesStaleCachedKeyAndReloadsLocalSecret() throws {
        try withTemporaryAPIKeyFile { fileURL in
            try BarnOwlAPIKeyStore.withTestingOverrides(
                environment: ["OPENAI_API_KEY": "sk-diagnostic"],
                localAPIKeyFileURL: fileURL,
                keychainReader: { _ in nil },
                keychainWriter: { _, _ in }
            ) {
                BarnOwlAPIKeyStore.clearMemoryCacheForTesting()

                let cachedKey = try BarnOwlAPIKeyStore.loadAPIKey()
                #expect(cachedKey == "sk-diagnostic")
            }

            try writeAPIKey("sk-valid-local\n", to: fileURL)

            try BarnOwlAPIKeyStore.withTestingOverrides(
                environment: [:],
                localAPIKeyFileURL: fileURL,
                keychainReader: { _ in nil },
                keychainWriter: { _, _ in }
            ) {
                let staleKey = try BarnOwlAPIKeyStore.loadAPIKey()
                #expect(staleKey == "sk-diagnostic")

                BarnOwlAPIKeyStore.invalidateCachedAPIKeyAfterAuthenticationFailure()

                let reloadedKey = try BarnOwlAPIKeyStore.loadAPIKey()
                #expect(reloadedKey == "sk-valid-local")
            }
        }
    }

    @Test
    func authenticationFailureSkipsStaleKeychainAndReloadsLocalSecret() throws {
        try withTemporaryAPIKeyFile { fileURL in
            let reader = KeychainReaderSpy(result: "sk-stale-keychain")
            let writer = KeychainWriterSpy()
            try writeAPIKey("sk-valid-local\n", to: fileURL)

            try BarnOwlAPIKeyStore.withTestingOverrides(
                environment: [:],
                localAPIKeyFileURL: fileURL,
                keychainReader: { allowsUserInteraction in
                    try reader.read(allowsUserInteraction: allowsUserInteraction)
                },
                keychainWriter: { apiKey, allowsUserInteraction in
                    writer.write(apiKey, allowsUserInteraction: allowsUserInteraction)
                }
            ) {
                BarnOwlAPIKeyStore.clearMemoryCacheForTesting()

                let staleKey = try BarnOwlAPIKeyStore.loadAPIKey()
                #expect(staleKey == "sk-stale-keychain")

                BarnOwlAPIKeyStore.invalidateCachedAPIKeyAfterAuthenticationFailure()

                let reloadedKey = try BarnOwlAPIKeyStore.loadAPIKey()
                #expect(reloadedKey == "sk-valid-local")
                #expect(reader.calls == [false])
                #expect(writer.values == ["sk-valid-local"])
                #expect(writer.interactionFlags == [false])
                #expect(!FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))
            }
        }
    }
}

@Suite
struct BarnOwlSettingsReadinessChecksTests {
    @Test
    func readinessLinesCombineAPIKeyDiagnosticsWithoutPrivatePaths() {
        let libraryURL = URL(fileURLWithPath: "/tmp/Barn Owl Library")

        let lines = BarnOwlSettingsReadinessChecks.lines(
            apiKeyDiagnostics: {
                [
                    "environment_configured=false",
                    "keychain_fallback=local_file_migration",
                    "local_file_path=/Users/alex/Library/Application Support/Barn Owl/openai_api_key"
                ]
            },
            libraryRoot: { libraryURL },
            contextRoot: { throw ReadinessTestError.unavailable },
            permissionDiagnostics: { [] }
        )

        #expect(
            lines == [
                "environment_configured=false",
                "keychain_fallback=local_file_migration",
                "local_file_path=[redacted local path]",
                "library_storage=writable",
                "local_context_storage=unavailable"
            ]
        )
        #expect(!lines.joined(separator: "\n").contains("/Users/alex"))
    }

    @MainActor
    @Test
    func firstRunReadinessRendersAllRequiredChecks() {
        let snapshot = BarnOwlFirstRunReadiness.snapshot(
            apiKeyConfigured: true,
            apiKeyVerified: true,
            microphoneDecision: .granted,
            systemAudioDecision: .granted,
            testRecordingSucceeded: true,
            storageAvailable: true,
            storagePath: "/tmp/Barn Owl Library",
            updateChannelConfigured: true
        )

        #expect(snapshot.checks.map(\.id) == BarnOwlReadinessCheck.ID.allCases)
        #expect(snapshot.criticalReady)
        #expect(snapshot.allReady)
    }

    @MainActor
    @Test
    func missingAPIKeyBlocksRecordingWithClearAction() throws {
        let snapshot = BarnOwlFirstRunReadiness.snapshot(
            apiKeyConfigured: false,
            apiKeyVerified: false,
            microphoneDecision: .granted,
            systemAudioDecision: .granted,
            testRecordingSucceeded: true,
            storageAvailable: true,
            storagePath: "/tmp/Barn Owl Library",
            updateChannelConfigured: true
        )

        let apiKeyCheck = try #require(snapshot.checks.first { $0.id == .apiKey })
        #expect(apiKeyCheck.state == .missing)
        #expect(apiKeyCheck.actionTitle == "Add Key Below")
        #expect(apiKeyCheck.action == .addAPIKey)
        #expect(!snapshot.criticalReady)
        #expect(snapshot.summary.contains("Finish the missing setup items"))
    }

    @MainActor
    @Test
    func savedButUntestedAPIKeyRequiresValidationBeforeSetupIsReady() throws {
        let snapshot = BarnOwlFirstRunReadiness.snapshot(
            apiKeyConfigured: true,
            apiKeyVerified: false,
            microphoneDecision: .granted,
            systemAudioDecision: .granted,
            testRecordingSucceeded: true,
            storageAvailable: true,
            storagePath: "/tmp/Barn Owl Library",
            updateChannelConfigured: true
        )

        let apiKeyCheck = try #require(snapshot.checks.first { $0.id == .apiKey })
        #expect(apiKeyCheck.state == .warning)
        #expect(apiKeyCheck.actionTitle == "Test Key")
        #expect(apiKeyCheck.action == .testAPIKey)
        #expect(!snapshot.criticalReady)
    }

    @MainActor
    @Test
    func undeterminedPermissionsOfferCaptureTestBeforeSystemSettings() throws {
        let snapshot = BarnOwlFirstRunReadiness.snapshot(
            apiKeyConfigured: true,
            apiKeyVerified: true,
            microphoneDecision: .notDetermined,
            systemAudioDecision: .notDetermined,
            testRecordingSucceeded: false,
            storageAvailable: true,
            storagePath: "/tmp/Barn Owl Library",
            updateChannelConfigured: true
        )

        let microphone = try #require(snapshot.checks.first { $0.id == .microphone })
        let systemAudio = try #require(snapshot.checks.first { $0.id == .systemAudio })

        #expect(microphone.state == .missing)
        #expect(microphone.actionTitle == "Run Test")
        #expect(microphone.action == .runCaptureTest)
        #expect(systemAudio.state == .missing)
        #expect(systemAudio.actionTitle == "Run Test")
        #expect(systemAudio.action == .runCaptureTest)
    }

    @MainActor
    @Test
    func deniedPermissionsOpenSystemSettings() throws {
        let snapshot = BarnOwlFirstRunReadiness.snapshot(
            apiKeyConfigured: true,
            apiKeyVerified: true,
            microphoneDecision: .denied,
            systemAudioDecision: .restricted,
            testRecordingSucceeded: false,
            storageAvailable: true,
            storagePath: "/tmp/Barn Owl Library",
            updateChannelConfigured: true
        )

        let microphone = try #require(snapshot.checks.first { $0.id == .microphone })
        let systemAudio = try #require(snapshot.checks.first { $0.id == .systemAudio })

        #expect(microphone.actionTitle == "Open Settings")
        #expect(microphone.action == .openMicrophoneSettings)
        #expect(systemAudio.actionTitle == "Open Settings")
        #expect(systemAudio.action == .openSystemAudioSettings)
    }

    @MainActor
    @Test
    func storageUnavailableReportsWarning() throws {
        let snapshot = BarnOwlFirstRunReadiness.snapshot(
            apiKeyConfigured: true,
            apiKeyVerified: true,
            microphoneDecision: .granted,
            systemAudioDecision: .granted,
            testRecordingSucceeded: true,
            storageAvailable: false,
            storagePath: nil,
            updateChannelConfigured: true
        )

        let storageCheck = try #require(snapshot.checks.first { $0.id == .storage })
        #expect(storageCheck.state == .warning)
        #expect(storageCheck.detail.contains("could not resolve or write"))
        #expect(!snapshot.criticalReady)
    }

    @MainActor
    @Test
    func completedChecklistDoesNotKeepNagging() {
        let snapshot = BarnOwlFirstRunReadiness.snapshot(
            apiKeyConfigured: true,
            apiKeyVerified: true,
            microphoneDecision: .granted,
            systemAudioDecision: .granted,
            testRecordingSucceeded: true,
            storageAvailable: true,
            storagePath: "/tmp/Barn Owl Library",
            updateChannelConfigured: true
        )

        #expect(snapshot.criticalReady)
        #expect(snapshot.allReady)
        #expect(snapshot.summary == "Barn Owl is ready to record, transcribe, save notes, and check for updates.")
    }

    @MainActor
    @Test
    func successfulCaptureKeepsMicrophoneDenialButTrustsVerifiedSystemAudio() {
        let snapshot = BarnOwlFirstRunReadiness.currentSnapshot(
            hasConfiguredAPIKey: true,
            hasVerifiedAPIKey: true,
            testRecordingSucceeded: false,
            microphoneCaptureSucceeded: true,
            systemAudioCaptureSucceeded: true,
            microphoneDecision: .denied,
            systemAudioDecision: .restricted
        )

        let microphone = snapshot.checks.first { $0.id == .microphone }
        let systemAudio = snapshot.checks.first { $0.id == .systemAudio }

        #expect(microphone?.state == .missing)
        #expect(microphone?.action == .openMicrophoneSettings)
        #expect(systemAudio?.state == .ready)
        #expect(systemAudio?.action == nil)
    }

    @MainActor
    @Test
    func systemAudioDenialStillOpensSettingsWithoutVerifiedCapture() {
        let snapshot = BarnOwlFirstRunReadiness.currentSnapshot(
            hasConfiguredAPIKey: true,
            hasVerifiedAPIKey: true,
            testRecordingSucceeded: false,
            microphoneCaptureSucceeded: false,
            systemAudioCaptureSucceeded: false,
            microphoneDecision: .granted,
            systemAudioDecision: .denied
        )

        let systemAudio = snapshot.checks.first { $0.id == .systemAudio }

        #expect(systemAudio?.state == .missing)
        #expect(systemAudio?.action == .openSystemAudioSettings)
    }
}

@Suite(.serialized)
struct BarnOwlCodexIntegrationTests {
    @Test
    func installCLIIsIdempotentAndUsesUserLocalSymlink() throws {
        try withTemporaryDirectory(prefix: "BarnOwlCodexCLITests") { rootURL in
            let bundledCLI = rootURL.appending(path: "bundle-barnowl", directoryHint: .notDirectory)
            try "#!/bin/sh\nexit 0\n".write(to: bundledCLI, atomically: true, encoding: .utf8)

            let installed = try BarnOwlCodexIntegration.installCLI(
                homeDirectory: rootURL,
                bundledCLIURL: bundledCLI
            )
            let installedAgain = try BarnOwlCodexIntegration.installCLI(
                homeDirectory: rootURL,
                bundledCLIURL: bundledCLI
            )

            #expect(installed == rootURL.appending(path: "bin/barnowl", directoryHint: .notDirectory))
            #expect(installedAgain == installed)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: installed.path) == bundledCLI.path)
        }
    }

    @Test
    func installCodexSkillWritesMarkerAndBacksUpUnmarkedSkill() throws {
        try withTemporaryDirectory(prefix: "BarnOwlCodexSkillTests") { rootURL in
            let bundledSkill = rootURL.appending(path: "BundledSkill/barnowl", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: bundledSkill.appending(path: "scripts", directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
            try "name: barnowl\n".write(
                to: bundledSkill.appending(path: "SKILL.md", directoryHint: .notDirectory),
                atomically: true,
                encoding: .utf8
            )
            try "#!/bin/sh\nexit 0\n".write(
                to: bundledSkill.appending(path: "scripts/barnowl", directoryHint: .notDirectory),
                atomically: true,
                encoding: .utf8
            )

            let existingSkill = rootURL.appending(path: ".codex/skills/barnowl", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: existingSkill, withIntermediateDirectories: true)
            try "user edit\n".write(
                to: existingSkill.appending(path: "SKILL.md", directoryHint: .notDirectory),
                atomically: true,
                encoding: .utf8
            )

            let installed = try BarnOwlCodexIntegration.installCodexSkill(
                homeDirectory: rootURL,
                bundledSkillURL: bundledSkill
            )
            _ = try BarnOwlCodexIntegration.installCodexSkill(
                homeDirectory: rootURL,
                bundledSkillURL: bundledSkill
            )

            let marker = installed.appending(path: ".barnowl-version", directoryHint: .notDirectory)
            let visibleSkillBackups = try FileManager.default.contentsOfDirectory(
                at: rootURL.appending(path: ".codex/skills", directoryHint: .isDirectory),
                includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.hasPrefix("barnowl.backup.") }
            let backups = try FileManager.default.contentsOfDirectory(
                at: rootURL.appending(path: ".codex/barnowl-skill-backups", directoryHint: .isDirectory),
                includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.hasPrefix("barnowl.backup.") }

            #expect(FileManager.default.fileExists(atPath: marker.path))
            #expect(visibleSkillBackups.isEmpty)
            #expect(backups.count == 1)
            #expect(FileManager.default.isExecutableFile(atPath: installed.appending(path: "scripts/barnowl").path))
        }
    }
}

@Suite
struct BarnOwlStatusDisplayHelperTests {
    @Test
    func recordingStatusDisplayNamesAreUserFacing() {
        #expect(RecordingStatus.idle.displayName == "Ready")
        #expect(RecordingStatus.preparing.displayName == "Preparing")
        #expect(RecordingStatus.recording.displayName == "Recording")
        #expect(RecordingStatus.processing.displayName == "Processing")
        #expect(RecordingStatus.failed.displayName == "Needs Attention")
    }

    @Test
    func recordingStatusRotationDegreesStaySmallForMenuMarkLayout() {
        #expect(RecordingStatus.idle.rotationDegrees == 1.5)
        #expect(RecordingStatus.preparing.rotationDegrees == 3)
        #expect(RecordingStatus.recording.rotationDegrees == 2)
        #expect(RecordingStatus.processing.rotationDegrees == 4)
        #expect(RecordingStatus.failed.rotationDegrees == 1.5)
    }
}

private enum ReadinessTestError: Error {
    case unavailable
}

private enum BarnOwlAPIKeyStoreTestError: Error {
    case needsInteraction
}

private final class KeychainReaderSpy: @unchecked Sendable {
    private let lock = NSLock()
    private let result: String?
    private let noninteractiveError: Error?
    private var storedCalls: [Bool] = []

    init(result: String?, noninteractiveError: Error? = nil) {
        self.result = result
        self.noninteractiveError = noninteractiveError
    }

    var calls: [Bool] {
        lock.withLock {
            storedCalls
        }
    }

    func read(allowsUserInteraction: Bool) throws -> String? {
        lock.withLock {
            storedCalls.append(allowsUserInteraction)
        }
        if !allowsUserInteraction,
           let noninteractiveError {
            throw noninteractiveError
        }
        return result
    }
}

private final class KeychainWriterSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [String] = []
    private var storedInteractionFlags: [Bool] = []

    var values: [String] {
        lock.withLock {
            storedValues
        }
    }

    var interactionFlags: [Bool] {
        lock.withLock {
            storedInteractionFlags
        }
    }

    func write(_ apiKey: String, allowsUserInteraction: Bool) {
        lock.withLock {
            storedValues.append(apiKey)
            storedInteractionFlags.append(allowsUserInteraction)
        }
    }
}

private func withTemporaryAPIKeyFile(_ body: (URL) throws -> Void) throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appending(path: "BarnOwlAPIKeyStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    let fileURL = rootURL
        .appending(path: "Secrets", directoryHint: .isDirectory)
        .appending(path: "openai-api-key", directoryHint: .notDirectory)
    defer {
        try? FileManager.default.removeItem(at: rootURL)
    }
    try body(fileURL)
}

private func withTemporaryDirectory(prefix: String, _ body: (URL) throws -> Void) throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appending(path: "\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer {
        try? FileManager.default.removeItem(at: rootURL)
    }
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try body(rootURL)
}

private func writeAPIKey(_ value: String, to fileURL: URL) throws {
    try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try value.write(to: fileURL, atomically: true, encoding: .utf8)
}

private func posixPermissions(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
    if let permissions = attributes[.posixPermissions] as? NSNumber {
        return permissions.intValue
    }
    return attributes[.posixPermissions] as? Int ?? 0
}
