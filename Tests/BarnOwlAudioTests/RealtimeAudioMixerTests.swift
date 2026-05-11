import BarnOwlAudio
import Foundation
import Testing

@Test
func realtimeMixerAlignsSourcesOnSharedTimeline() {
    var mixer = RealtimeAudioMixer(configuration: RealtimeAudioMixerConfiguration(
        sampleRate: 4,
        outputFrameCount: 4,
        alignmentHoldbackFrameCount: 4,
        microphoneGain: 1,
        systemAudioGain: 1,
        limiterThreshold: 0.99
    ))

    let microphone = RealtimeAudioMixerInputChunk(
        trackKind: .microphone,
        pcm16Data: pcm16Data([1_000, 1_000, 1_000, 1_000]),
        sampleRate: 4,
        timelineStartFrame: 0
    )
    let systemAudio = RealtimeAudioMixerInputChunk(
        trackKind: .systemAudio,
        pcm16Data: pcm16Data([2_000, 2_000]),
        sampleRate: 4,
        timelineStartFrame: 2
    )

    #expect(mixer.append(microphone).isEmpty)
    #expect(mixer.append(systemAudio).isEmpty)

    let output = mixer.flush()
    #expect(output.count == 1)
    #expect(pcm16Samples(output[0].pcm16Data) == [1_000, 1_000, 3_000, 3_000])
    #expect(output[0].timelineStartFrame == 0)
}

@Test
func realtimeMixerFillsMissingSourceWithSilence() {
    var mixer = RealtimeAudioMixer(configuration: RealtimeAudioMixerConfiguration(
        sampleRate: 4,
        outputFrameCount: 4,
        alignmentHoldbackFrameCount: 0,
        microphoneGain: 1,
        systemAudioGain: 1,
        limiterThreshold: 0.99
    ))

    let output = mixer.append(RealtimeAudioMixerInputChunk(
        trackKind: .microphone,
        pcm16Data: pcm16Data([750, 750, 750, 750]),
        sampleRate: 4,
        timelineStartFrame: 0
    ))

    #expect(output.count == 1)
    #expect(pcm16Samples(output[0].pcm16Data) == [750, 750, 750, 750])
}

@Test
func realtimeMixerAppliesSourceGainAndSoftLimiter() {
    var mixer = RealtimeAudioMixer(configuration: RealtimeAudioMixerConfiguration(
        sampleRate: 4,
        outputFrameCount: 1,
        alignmentHoldbackFrameCount: 0,
        microphoneGain: 0.5,
        systemAudioGain: 1,
        limiterThreshold: 0.80
    ))

    let microphoneOutput = mixer.append(RealtimeAudioMixerInputChunk(
        trackKind: .microphone,
        pcm16Data: pcm16Data([20_000]),
        sampleRate: 4,
        timelineStartFrame: 0
    ))
    #expect(pcm16Samples(microphoneOutput[0].pcm16Data) == [10_000])

    let limitedOutput = mixer.append(RealtimeAudioMixerInputChunk(
        trackKind: .systemAudio,
        pcm16Data: pcm16Data([32_000]),
        sampleRate: 4,
        timelineStartFrame: 1
    ))
    let limitedSample = pcm16Samples(limitedOutput[0].pcm16Data)[0]
    #expect(limitedSample < Int16.max)
    #expect(limitedSample > 26_000)
}

private func pcm16Data(_ samples: [Int16]) -> Data {
    var data = Data()
    for sample in samples {
        var littleEndian = sample.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
    return data
}

private func pcm16Samples(_ data: Data) -> [Int16] {
    let sampleCount = data.count / MemoryLayout<Int16>.size
    return data.withUnsafeBytes { rawBuffer in
        let bytes = rawBuffer.bindMemory(to: UInt8.self)
        return (0..<sampleCount).map { index in
            let low = UInt16(bytes[index * 2])
            let high = UInt16(bytes[index * 2 + 1]) << 8
            return Int16(bitPattern: low | high)
        }
    }
}
