import BarnOwlAudio
import Foundation
import ScreenCaptureKit
import Testing

@Test
func systemAudioOnlySettingsBuildAudioOnlyScreenCaptureConfiguration() {
    let settings = SystemAudioCaptureStreamSettings.systemAudioOnly
    let configuration = settings.makeScreenCaptureKitConfiguration()

    #expect(configuration.capturesAudio)
    #expect(!configuration.captureMicrophone)
    #expect(configuration.excludesCurrentProcessAudio)
    #expect(configuration.sampleRate == 48_000)
    #expect(configuration.channelCount == 2)
    #expect(configuration.width == 1)
    #expect(configuration.height == 1)
    #expect(configuration.queueDepth == 1)
    #expect(!configuration.showsCursor)
}

@Test
func displaySelectionPrefersMainDisplay() {
    let displays = [
        SystemAudioCaptureDisplay(displayID: 200, width: 6_016, height: 3_384, isMainDisplay: false),
        SystemAudioCaptureDisplay(displayID: 100, width: 1_920, height: 1_080, isMainDisplay: true)
    ]

    let selected = SystemAudioCaptureSourceSelection.selectDisplay(from: displays)

    #expect(selected?.displayID == 100)
}

@Test
func displaySelectionFallsBackToLargestDisplay() {
    let displays = [
        SystemAudioCaptureDisplay(displayID: 100, width: 1_920, height: 1_080, isMainDisplay: false),
        SystemAudioCaptureDisplay(displayID: 200, width: 3_456, height: 2_234, isMainDisplay: false)
    ]

    let selected = SystemAudioCaptureSourceSelection.selectDisplay(from: displays)

    #expect(selected?.displayID == 200)
}

@Test
func displaySelectionReturnsNilWhenNoDisplaysAreAvailable() {
    let selected = SystemAudioCaptureSourceSelection.selectDisplay(from: [])

    #expect(selected == nil)
}

@Test
func screenCaptureKitUserDeclinedMapsToPermissionDenied() {
    let error = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)

    let mappedError = SystemAudioCaptureSourceSelection.audioCaptureError(for: error)

    #expect(mappedError == .permissionDenied)
}

@Test
func screenCaptureKitUnavailableSourceErrorsMapToSourceUnavailable() {
    let error = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.noDisplayList.rawValue)

    let mappedError = SystemAudioCaptureSourceSelection.audioCaptureError(for: error)

    #expect(mappedError == .sourceUnavailable)
}
