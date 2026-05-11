import Foundation

public enum PerformanceMilestone: String, Codable, Equatable, Sendable {
    case captureStarted
    case firstAudioChunkCaptured
    case captureStopped
    case realtimePreviewStarted
    case firstRealtimeTranscriptReceived
    case transcriptionStarted
    case firstTranscriptReceived
    case finalTranscriptReceived
    case finalProcessingFinished
}

public enum PerformancePhase: String, Codable, Equatable, Sendable {
    case capture
    case realtimePreview
    case finalProcessing
    case transcription
    case tokenization
    case modelRequest
    case tempAudio
    case cleanup
}

public enum PerformancePhaseBoundary: String, Codable, Equatable, Sendable {
    case started
    case finished
}

public enum PerformanceMetricEventKind: String, Codable, Equatable, Sendable {
    case milestone
    case phaseBoundary
    case tempAudioBytes
}

public struct PerformancePhaseKey: Codable, Equatable, Hashable, Sendable {
    public var phase: PerformancePhase
    public var model: String?

    public init(phase: PerformancePhase, model: String? = nil) {
        self.phase = phase
        self.model = model
    }
}

public struct PerformanceMetricEvent: Codable, Equatable, Sendable {
    public var kind: PerformanceMetricEventKind
    public var occurredAt: TimeInterval
    public var milestone: PerformanceMilestone?
    public var phase: PerformancePhase?
    public var boundary: PerformancePhaseBoundary?
    public var model: String?
    public var byteCount: Int64?

    public init(
        kind: PerformanceMetricEventKind,
        occurredAt: TimeInterval,
        milestone: PerformanceMilestone? = nil,
        phase: PerformancePhase? = nil,
        boundary: PerformancePhaseBoundary? = nil,
        model: String? = nil,
        byteCount: Int64? = nil
    ) {
        self.kind = kind
        self.occurredAt = occurredAt
        self.milestone = milestone
        self.phase = phase
        self.boundary = boundary
        self.model = model
        self.byteCount = byteCount
    }

    public static func milestone(
        _ milestone: PerformanceMilestone,
        at occurredAt: TimeInterval
    ) -> PerformanceMetricEvent {
        PerformanceMetricEvent(
            kind: .milestone,
            occurredAt: occurredAt,
            milestone: milestone
        )
    }

    public static func phase(
        _ phase: PerformancePhase,
        _ boundary: PerformancePhaseBoundary,
        at occurredAt: TimeInterval,
        model: String? = nil
    ) -> PerformanceMetricEvent {
        PerformanceMetricEvent(
            kind: .phaseBoundary,
            occurredAt: occurredAt,
            phase: phase,
            boundary: boundary,
            model: model
        )
    }

    public static func tempAudioBytes(
        _ byteCount: Int64,
        at occurredAt: TimeInterval
    ) -> PerformanceMetricEvent {
        PerformanceMetricEvent(
            kind: .tempAudioBytes,
            occurredAt: occurredAt,
            byteCount: byteCount
        )
    }
}

public struct PerformancePhaseDuration: Codable, Equatable, Sendable {
    public var key: PerformancePhaseKey
    public var startedAt: TimeInterval
    public var finishedAt: TimeInterval

    public init(
        key: PerformancePhaseKey,
        startedAt: TimeInterval,
        finishedAt: TimeInterval
    ) {
        self.key = key
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public var duration: TimeInterval {
        finishedAt - startedAt
    }
}

public struct PerformanceMetricSummary: Codable, Equatable, Sendable {
    public var eventCount: Int
    public var captureLatency: TimeInterval?
    public var captureDuration: TimeInterval?
    public var realtimePreviewLatency: TimeInterval?
    public var realtimePreviewDuration: TimeInterval?
    public var firstTranscriptLatency: TimeInterval?
    public var finalTranscriptDuration: TimeInterval?
    public var finalProcessingDuration: TimeInterval?
    public var cleanupDuration: TimeInterval?
    public var maxTempAudioBytes: Int64?
    public var finalTempAudioBytes: Int64?
    public var phaseDurations: [PerformancePhaseDuration]

    public init(
        eventCount: Int = 0,
        captureLatency: TimeInterval? = nil,
        captureDuration: TimeInterval? = nil,
        realtimePreviewLatency: TimeInterval? = nil,
        realtimePreviewDuration: TimeInterval? = nil,
        firstTranscriptLatency: TimeInterval? = nil,
        finalTranscriptDuration: TimeInterval? = nil,
        finalProcessingDuration: TimeInterval? = nil,
        cleanupDuration: TimeInterval? = nil,
        maxTempAudioBytes: Int64? = nil,
        finalTempAudioBytes: Int64? = nil,
        phaseDurations: [PerformancePhaseDuration] = []
    ) {
        self.eventCount = eventCount
        self.captureLatency = captureLatency
        self.captureDuration = captureDuration
        self.realtimePreviewLatency = realtimePreviewLatency
        self.realtimePreviewDuration = realtimePreviewDuration
        self.firstTranscriptLatency = firstTranscriptLatency
        self.finalTranscriptDuration = finalTranscriptDuration
        self.finalProcessingDuration = finalProcessingDuration
        self.cleanupDuration = cleanupDuration
        self.maxTempAudioBytes = maxTempAudioBytes
        self.finalTempAudioBytes = finalTempAudioBytes
        self.phaseDurations = phaseDurations
    }

    public func totalDuration(for key: PerformancePhaseKey) -> TimeInterval {
        phaseDurations
            .filter { $0.key == key }
            .reduce(0) { $0 + $1.duration }
    }
}

public struct PerformanceMetricAccumulator: Equatable, Sendable {
    public private(set) var events: [PerformanceMetricEvent]

    public init(events: [PerformanceMetricEvent] = []) {
        self.events = events
    }

    public mutating func record(_ event: PerformanceMetricEvent) {
        events.append(event)
    }

    public func summary() -> PerformanceMetricSummary {
        PerformanceMetrics.aggregate(events)
    }
}

public enum PerformanceMetrics {
    public static func aggregate(
        _ events: [PerformanceMetricEvent]
    ) -> PerformanceMetricSummary {
        let orderedEvents = events.sorted { lhs, rhs in
            lhs.occurredAt < rhs.occurredAt
        }
        let milestones = aggregateMilestones(orderedEvents)
        let tempAudioBytes = orderedEvents.compactMap(\.byteCount)
        let phaseDurations = aggregatePhaseDurations(orderedEvents)

        let cleanupKey = PerformancePhaseKey(phase: .cleanup)
        let cleanupDurations = phaseDurations.filter { $0.key == cleanupKey }
        let cleanupDuration = cleanupDurations.reduce(0) { $0 + $1.duration }
        let captureDuration = totalDuration(for: .capture, in: phaseDurations)
        let realtimePreviewDuration = totalDuration(for: .realtimePreview, in: phaseDurations)
        let finalProcessingDuration = totalDuration(for: .finalProcessing, in: phaseDurations)

        return PerformanceMetricSummary(
            eventCount: events.count,
            captureLatency: duration(
                from: milestones[.captureStarted],
                to: milestones[.firstAudioChunkCaptured]
            ),
            captureDuration: captureDuration,
            realtimePreviewLatency: duration(
                from: milestones[.realtimePreviewStarted],
                to: milestones[.firstRealtimeTranscriptReceived]
            ),
            realtimePreviewDuration: realtimePreviewDuration,
            firstTranscriptLatency: duration(
                from: milestones[.transcriptionStarted],
                to: milestones[.firstTranscriptReceived]
            ),
            finalTranscriptDuration: duration(
                from: milestones[.transcriptionStarted],
                to: milestones[.finalTranscriptReceived]
            ),
            finalProcessingDuration: finalProcessingDuration,
            cleanupDuration: cleanupDurations.isEmpty ? nil : cleanupDuration,
            maxTempAudioBytes: tempAudioBytes.max(),
            finalTempAudioBytes: tempAudioBytes.last,
            phaseDurations: phaseDurations
        )
    }

    private static func aggregateMilestones(
        _ events: [PerformanceMetricEvent]
    ) -> [PerformanceMilestone: TimeInterval] {
        var milestones: [PerformanceMilestone: TimeInterval] = [:]

        for event in events where event.kind == .milestone {
            guard let milestone = event.milestone else {
                continue
            }

            switch milestone {
            case .captureStopped, .finalTranscriptReceived, .finalProcessingFinished:
                milestones[milestone] = event.occurredAt
            default:
                if milestones[milestone] == nil {
                    milestones[milestone] = event.occurredAt
                }
            }
        }

        return milestones
    }

    private static func aggregatePhaseDurations(
        _ events: [PerformanceMetricEvent]
    ) -> [PerformancePhaseDuration] {
        var startsByKey: [PerformancePhaseKey: [TimeInterval]] = [:]
        var durations: [PerformancePhaseDuration] = []

        for event in events where event.kind == .phaseBoundary {
            guard let phase = event.phase, let boundary = event.boundary else {
                continue
            }

            let key = PerformancePhaseKey(phase: phase, model: event.model)

            switch boundary {
            case .started:
                startsByKey[key, default: []].append(event.occurredAt)
            case .finished:
                guard var starts = startsByKey[key], !starts.isEmpty else {
                    continue
                }

                let startedAt = starts.removeFirst()
                startsByKey[key] = starts

                guard event.occurredAt >= startedAt else {
                    continue
                }

                durations.append(
                    PerformancePhaseDuration(
                        key: key,
                        startedAt: startedAt,
                        finishedAt: event.occurredAt
                    )
                )
            }
        }

        return durations
    }

    private static func duration(
        from start: TimeInterval?,
        to end: TimeInterval?
    ) -> TimeInterval? {
        guard let start, let end, end >= start else {
            return nil
        }

        return end - start
    }

    private static func totalDuration(
        for phase: PerformancePhase,
        in durations: [PerformancePhaseDuration]
    ) -> TimeInterval? {
        let matchingDurations = durations.filter { $0.key.phase == phase }
        guard !matchingDurations.isEmpty else { return nil }
        return matchingDurations.reduce(0) { $0 + $1.duration }
    }
}
