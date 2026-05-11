import Foundation

public struct RealtimeAudioMixerConfiguration: Equatable, Sendable {
    public var sampleRate: Int
    public var outputFrameCount: Int
    public var alignmentHoldbackFrameCount: Int
    public var microphoneGain: Float
    public var systemAudioGain: Float
    public var limiterThreshold: Float

    public init(
        sampleRate: Int = 24_000,
        outputFrameCount: Int = 6_000,
        alignmentHoldbackFrameCount: Int = 6_000,
        microphoneGain: Float = 1,
        systemAudioGain: Float = 1,
        limiterThreshold: Float = 0.92
    ) {
        self.sampleRate = sampleRate
        self.outputFrameCount = outputFrameCount
        self.alignmentHoldbackFrameCount = alignmentHoldbackFrameCount
        self.microphoneGain = microphoneGain
        self.systemAudioGain = systemAudioGain
        self.limiterThreshold = limiterThreshold
    }

    public static let barnOwlRealtimeTranscription = RealtimeAudioMixerConfiguration()
}

public struct RealtimeAudioMixerInputChunk: Equatable, Sendable {
    public var trackKind: AudioTrackKind
    public var pcm16Data: Data
    public var sampleRate: Int
    public var timelineStartFrame: Int64

    public init(
        trackKind: AudioTrackKind,
        pcm16Data: Data,
        sampleRate: Int,
        timelineStartFrame: Int64
    ) {
        self.trackKind = trackKind
        self.pcm16Data = pcm16Data
        self.sampleRate = sampleRate
        self.timelineStartFrame = timelineStartFrame
    }
}

public struct RealtimeAudioMixerOutputChunk: Equatable, Sendable {
    public var pcm16Data: Data
    public var sampleRate: Int
    public var timelineStartFrame: Int64
    public var duration: TimeInterval

    public init(
        pcm16Data: Data,
        sampleRate: Int,
        timelineStartFrame: Int64,
        duration: TimeInterval
    ) {
        self.pcm16Data = pcm16Data
        self.sampleRate = sampleRate
        self.timelineStartFrame = timelineStartFrame
        self.duration = duration
    }
}

public struct RealtimeAudioMixer: Sendable {
    private let configuration: RealtimeAudioMixerConfiguration
    private var pendingSamplesByTrack: [AudioTrackKind: [Int64: Int16]] = [:]
    private var nextOutputFrame: Int64 = 0
    private var maxReceivedEndFrame: Int64 = 0

    public init(configuration: RealtimeAudioMixerConfiguration = .barnOwlRealtimeTranscription) {
        self.configuration = configuration
    }

    public mutating func append(_ chunk: RealtimeAudioMixerInputChunk) -> [RealtimeAudioMixerOutputChunk] {
        guard chunk.sampleRate == configuration.sampleRate,
              chunk.trackKind == .microphone || chunk.trackKind == .systemAudio
        else {
            return []
        }

        let samples = Self.decodePCM16(chunk.pcm16Data)
        guard !samples.isEmpty else {
            return []
        }

        var pending = pendingSamplesByTrack[chunk.trackKind, default: [:]]
        for (offset, sample) in samples.enumerated() {
            let frame = chunk.timelineStartFrame + Int64(offset)
            guard frame >= nextOutputFrame else {
                continue
            }
            pending[frame] = sample
        }
        pendingSamplesByTrack[chunk.trackKind] = pending
        maxReceivedEndFrame = max(maxReceivedEndFrame, chunk.timelineStartFrame + Int64(samples.count))

        return drain(isFinal: false)
    }

    public mutating func flush() -> [RealtimeAudioMixerOutputChunk] {
        let output = drain(isFinal: true)
        pendingSamplesByTrack = [:]
        return output
    }

    private mutating func drain(isFinal: Bool) -> [RealtimeAudioMixerOutputChunk] {
        guard configuration.sampleRate > 0,
              configuration.outputFrameCount > 0
        else {
            return []
        }

        let holdback = isFinal ? 0 : max(configuration.alignmentHoldbackFrameCount, 0)
        let availableEndFrame = max(nextOutputFrame, maxReceivedEndFrame - Int64(holdback))
        var output: [RealtimeAudioMixerOutputChunk] = []

        while nextOutputFrame < availableEndFrame {
            let remaining = availableEndFrame - nextOutputFrame
            guard isFinal || remaining >= Int64(configuration.outputFrameCount) else {
                break
            }

            let frameCount = Int(min(Int64(configuration.outputFrameCount), remaining))
            output.append(mixChunk(startFrame: nextOutputFrame, frameCount: frameCount))
            nextOutputFrame += Int64(frameCount)
        }

        return output
    }

    private mutating func mixChunk(startFrame: Int64, frameCount: Int) -> RealtimeAudioMixerOutputChunk {
        var microphoneSamples = pendingSamplesByTrack[.microphone, default: [:]]
        var systemAudioSamples = pendingSamplesByTrack[.systemAudio, default: [:]]
        var outputSamples = [Int16]()
        outputSamples.reserveCapacity(frameCount)

        for offset in 0..<frameCount {
            let frame = startFrame + Int64(offset)
            var mixed: Float = 0
            if let sample = microphoneSamples.removeValue(forKey: frame) {
                mixed += Self.normalized(sample) * configuration.microphoneGain
            }
            if let sample = systemAudioSamples.removeValue(forKey: frame) {
                mixed += Self.normalized(sample) * configuration.systemAudioGain
            }
            outputSamples.append(Self.encodePCM16(Self.softLimit(mixed, threshold: configuration.limiterThreshold)))
        }

        pendingSamplesByTrack[.microphone] = microphoneSamples.isEmpty ? nil : microphoneSamples
        pendingSamplesByTrack[.systemAudio] = systemAudioSamples.isEmpty ? nil : systemAudioSamples

        return RealtimeAudioMixerOutputChunk(
            pcm16Data: Self.encodePCM16Data(outputSamples),
            sampleRate: configuration.sampleRate,
            timelineStartFrame: startFrame,
            duration: TimeInterval(frameCount) / TimeInterval(configuration.sampleRate)
        )
    }

    private static func decodePCM16(_ data: Data) -> [Int16] {
        guard data.count >= MemoryLayout<Int16>.size else {
            return []
        }

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

    private static func encodePCM16Data(_ samples: [Int16]) -> Data {
        var data = Data()
        data.reserveCapacity(samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            var littleEndian = sample.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func normalized(_ sample: Int16) -> Float {
        Float(sample) / Float(Int16.max)
    }

    private static func encodePCM16(_ sample: Float) -> Int16 {
        let clamped = min(max(sample, -1), 1)
        return Int16((clamped * Float(Int16.max)).rounded())
    }

    private static func softLimit(_ sample: Float, threshold: Float) -> Float {
        let limitedThreshold = min(max(threshold, 0.001), 0.999)
        let magnitude = abs(sample)
        guard magnitude > limitedThreshold else {
            return sample
        }

        let headroom = 1 - limitedThreshold
        let limitedMagnitude = limitedThreshold + headroom * tanh((magnitude - limitedThreshold) / headroom)
        return copysign(min(limitedMagnitude, 1), sample)
    }
}
