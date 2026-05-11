@preconcurrency import AVFoundation
import BarnOwlAudio
import BarnOwlCore
import Testing

private final class FakeMicrophoneCaptureDriver: MicrophoneCaptureDriving, @unchecked Sendable {
    var inputFormatCallCount = 0
    var installTapCallCount = 0
    var removeTapCallCount = 0
    var prepareCallCount = 0
    var startCallCount = 0
    var stopCallCount = 0
    var startError: Error?
    var installTapError: Error?
    var installedTap: MicrophoneCaptureTapBlock?
    private(set) var isRunning = false

    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

    func inputFormat() -> AVAudioFormat {
        inputFormatCallCount += 1
        return format
    }

    func installInputTap(
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat,
        block: @escaping MicrophoneCaptureTapBlock
    ) throws {
        _ = bufferSize
        _ = format
        installTapCallCount += 1
        if let installTapError {
            throw installTapError
        }
        installedTap = block
    }

    func removeInputTap() {
        removeTapCallCount += 1
        installedTap = nil
    }

    func prepare() {
        prepareCallCount += 1
    }

    func start() throws {
        startCallCount += 1
        if let startError {
            throw startError
        }
        isRunning = true
    }

    func stop() {
        stopCallCount += 1
        isRunning = false
    }

    func emitBuffer() {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!
        buffer.frameLength = 16
        installedTap?(buffer, AVAudioTime(sampleTime: 0, atRate: format.sampleRate))
    }
}

private final class RecordingMicrophoneBufferWriter: MicrophoneCaptureBufferWriting, @unchecked Sendable {
    var writeCount = 0
    var lastFrameLength: AVAudioFrameCount?

    func writeMicrophoneBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) throws {
        _ = time
        writeCount += 1
        lastFrameLength = buffer.frameLength
    }
}

@Test
func microphoneCaptureStartIsNoOpWhenMicrophoneCaptureIsDisabled() async throws {
    let driver = FakeMicrophoneCaptureDriver()
    let writer = RecordingMicrophoneBufferWriter()
    let source = AVAudioEngineMicrophoneCaptureSource(writer: writer, driver: driver)

    try await source.startMicrophoneCapture(configuration: AudioSourceConfiguration(
        capturesMicrophone: false,
        capturesSystemAudio: true
    ))
    await source.stopMicrophoneCapture()

    #expect(!source.isCapturing)
    #expect(driver.inputFormatCallCount == 0)
    #expect(driver.installTapCallCount == 0)
    #expect(driver.startCallCount == 0)
    #expect(driver.removeTapCallCount == 0)
    #expect(driver.stopCallCount == 0)
    #expect(writer.writeCount == 0)
}

@Test
func microphoneCaptureStartAndStopAreIdempotent() async throws {
    let driver = FakeMicrophoneCaptureDriver()
    let writer = RecordingMicrophoneBufferWriter()
    let source = AVAudioEngineMicrophoneCaptureSource(writer: writer, driver: driver)
    let configuration = AudioSourceConfiguration(capturesMicrophone: true, capturesSystemAudio: false)

    try await source.startMicrophoneCapture(configuration: configuration)
    try await source.startMicrophoneCapture(configuration: configuration)

    #expect(source.isCapturing)
    #expect(driver.inputFormatCallCount == 1)
    #expect(driver.installTapCallCount == 1)
    #expect(driver.prepareCallCount == 1)
    #expect(driver.startCallCount == 1)

    await source.stopMicrophoneCapture()
    await source.stopMicrophoneCapture()

    #expect(!source.isCapturing)
    #expect(driver.removeTapCallCount == 1)
    #expect(driver.stopCallCount == 1)
}

@Test
func microphoneCaptureRoutesTappedBuffersToWriter() async throws {
    let driver = FakeMicrophoneCaptureDriver()
    let writer = RecordingMicrophoneBufferWriter()
    let source = AVAudioEngineMicrophoneCaptureSource(writer: writer, driver: driver)

    try await source.startMicrophoneCapture(configuration: AudioSourceConfiguration(
        capturesMicrophone: true,
        capturesSystemAudio: false
    ))
    driver.emitBuffer()
    await source.stopMicrophoneCapture()

    #expect(writer.writeCount == 1)
    #expect(writer.lastFrameLength == 16)
}

@Test
func microphoneCaptureCleansUpTapWhenEngineStartFails() async {
    let driver = FakeMicrophoneCaptureDriver()
    let writer = RecordingMicrophoneBufferWriter()
    let source = AVAudioEngineMicrophoneCaptureSource(writer: writer, driver: driver)
    driver.startError = AudioCaptureError.sourceUnavailable

    var sourceUnavailable = false
    do {
        try await source.startMicrophoneCapture(configuration: AudioSourceConfiguration(
            capturesMicrophone: true,
            capturesSystemAudio: false
        ))
    } catch AudioCaptureError.sourceUnavailable {
        sourceUnavailable = true
    } catch {
        #expect(Bool(false), "Unexpected error: \(error)")
    }

    #expect(sourceUnavailable)
    #expect(!source.isCapturing)
    #expect(driver.installTapCallCount == 1)
    #expect(driver.removeTapCallCount == 1)
    #expect(driver.stopCallCount == 1)
}
