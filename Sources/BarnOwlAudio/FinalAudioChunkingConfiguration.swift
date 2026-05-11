import Foundation

public struct FinalAudioChunkingConfiguration: Equatable, Sendable {
    public var chunkDuration: TimeInterval
    public var overlapDuration: TimeInterval

    public var strideDuration: TimeInterval {
        max(0, chunkDuration - overlapDuration)
    }

    public init(
        chunkDuration: TimeInterval = 60,
        overlapDuration: TimeInterval = 5
    ) {
        self.chunkDuration = max(1, chunkDuration)
        self.overlapDuration = min(max(0, overlapDuration), max(0, chunkDuration - 0.001))
    }

    public func startTimeOffset(forSequenceNumber sequenceNumber: Int) -> TimeInterval {
        TimeInterval(max(0, sequenceNumber)) * strideDuration
    }

    public static let barnOwlFinalTranscription = FinalAudioChunkingConfiguration(
        chunkDuration: 60,
        overlapDuration: 5
    )
}
