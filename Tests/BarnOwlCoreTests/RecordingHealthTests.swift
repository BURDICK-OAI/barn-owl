import BarnOwlCore
import Foundation
import Testing

@Test
func rmsLevelHistoryKeepsLatestSamplesAndComputesLevels() {
    var history = RMSLevelHistory(capacity: 2)

    history.record(rms: 0.2, at: 10)
    history.record(rms: 2, at: 30)
    history.record(rms: -1, at: 20)

    #expect(history.samples.map(\.occurredAt) == [20, 30])
    #expect(history.samples.map(\.rms) == [0, 1])
    #expect(history.latestRMS == 1)
    #expect(history.averageRMS == 0.5)
    #expect(history.peakRMS == 1)
}

@Test
func pcm16RMSLevelCalculatesExpectedValue() {
    let samples = [Int16(0), Int16(16_384), Int16(-16_384), Int16(0)]
    let sampleLevel = RMSLevelMeter.rmsLevel(forPCM16Samples: samples)
    var mutableSamples = samples
    let data = Data(
        bytes: &mutableSamples,
        count: mutableSamples.count * MemoryLayout<Int16>.size
    )
    let dataLevel = RMSLevelMeter.rmsLevel(forPCM16Data: data)

    #expect(abs(sampleLevel - 0.353553) < 0.0001)
    #expect(abs(dataLevel - sampleLevel) < 0.0001)
    #expect(RMSLevelMeter.rmsLevel(forPCM16Data: Data([0])) == 0)
}

@Test
func systemAudioSilenceWarningUsesPolicyThreshold() {
    let policy = RecordingHealthPolicy(
        rmsSilenceThreshold: 0.01,
        systemSilenceWarningThreshold: 10
    )
    let systemAudio = RecordingSourceHealthSnapshot(
        source: .systemAudio,
        isEnabled: true,
        isCapturing: true
    )
    .recordingRMSLevel(0.001, at: 0)
    .recordingRMSLevel(0.002, at: 5)
    .recordingRMSLevel(0.001, at: 10)

    let warnings = systemAudio.warnings(at: 12, policy: policy)

    #expect(warnings.count == 1)
    #expect(warnings.first?.kind == .systemAudioSilent)
    #expect(warnings.first?.source == .systemAudio)
    #expect(warnings.first?.duration == 12)

    let microphone = RecordingSourceHealthSnapshot(
        source: .microphone,
        isEnabled: true,
        isCapturing: true
    )
    .recordingRMSLevel(0, at: 0)
    .recordingRMSLevel(0, at: 12)

    #expect(microphone.warnings(at: 12, policy: policy).isEmpty)

    let recentlyLoudSystemAudio = systemAudio.recordingRMSLevel(0.2, at: 11)

    #expect(recentlyLoudSystemAudio.warnings(at: 12, policy: policy).isEmpty)
}

@Test
func healthErrorHistoryTracksHelperAndSourceErrors() {
    let sourceError = RecordingHealthError(
        origin: .helper,
        severity: .blocking,
        code: "tap-failed",
        message: "Tap failed.",
        occurredAt: 20
    )
    let helperError = RecordingHealthError(
        origin: .source,
        severity: .recoverable,
        code: "helper-restarted",
        message: "Helper restarted.",
        occurredAt: 30,
        source: .systemAudio
    )

    let microphone = RecordingSourceHealthSnapshot(source: .microphone)
        .recordingError(sourceError)
    let health = RecordingHealthSnapshot(microphone: microphone)
        .recordingHelperError(helperError)

    #expect(health.microphone.errorHistory.latest?.origin == .source)
    #expect(health.microphone.errorHistory.latest?.source == .microphone)
    #expect(health.microphone.blockingErrors.count == 1)
    #expect(health.helperErrors.latest?.origin == .helper)
    #expect(health.helperErrors.latest?.source == nil)
    #expect(health.helperErrors.latest(origin: .helper)?.code == "helper-restarted")
}

@Test
func readinessSummaryBlocksOnMissingPermissionsAndBlockingErrors() {
    let permissions = RecordingPermissionSet(
        microphone: .init(kind: .microphone, decision: .granted),
        systemAudio: .init(kind: .systemAudioScreenCapture, decision: .denied)
    )

    let missingPermissionSummary = RecordingHealthSnapshot.idle.readinessSummary(
        configuration: .defaultMeetingCapture,
        permissions: permissions,
        now: 0
    )

    #expect(missingPermissionSummary.state == .blocked)
    #expect(!missingPermissionSummary.isReadyToRecord)
    #expect(missingPermissionSummary.missingPermissions == [.systemAudioScreenCapture])

    let helperError = RecordingHealthError(
        origin: .helper,
        severity: .blocking,
        code: "helper-not-running",
        message: "Helper is not running.",
        occurredAt: 40
    )
    let errorSummary = RecordingHealthSnapshot.idle
        .recordingHelperError(helperError)
        .readinessSummary(
            configuration: .defaultMeetingCapture,
            permissions: .grantedForDefaultMeetingCapture,
            now: 40
        )

    #expect(errorSummary.state == .blocked)
    #expect(errorSummary.blockingErrorCount == 1)
    #expect(errorSummary.helperErrorCount == 1)
}

@Test
func readinessSummaryStaysReadyForExpectedSystemSilenceWarning() {
    let systemAudio = RecordingSourceHealthSnapshot(
        source: .systemAudio,
        isEnabled: true,
        isCapturing: true
    )
    .recordingRMSLevel(0, at: 0)
    .recordingRMSLevel(0, at: 11)
    let health = RecordingHealthSnapshot(systemAudio: systemAudio)
    let summary = health.readinessSummary(
        configuration: .defaultMeetingCapture,
        permissions: .grantedForDefaultMeetingCapture,
        now: 12
    )

    #expect(summary.state == .ready)
    #expect(summary.message == "Recording ready. System audio is quiet.")
    #expect(summary.isReadyToRecord)
    #expect(summary.warningCount == 1)
    #expect(summary.requiredSources == [.microphone, .systemAudio])

    let cleanSummary = RecordingHealthSnapshot.idle.readinessSummary(
        configuration: AudioSourceConfiguration(capturesMicrophone: true, capturesSystemAudio: false),
        permissions: .grantedForDefaultMeetingCapture,
        now: 12
    )

    #expect(cleanSummary.state == .ready)
    #expect(cleanSummary.requiredSources == [.microphone])
}
