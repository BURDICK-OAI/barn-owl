import BarnOwlCore
import Foundation

public struct TranscribedAudioFile: Equatable, Sendable {
    public var audioFile: RecordedAudioFile
    public var segments: [TranscriptSegment]

    public init(audioFile: RecordedAudioFile, segments: [TranscriptSegment]) {
        self.audioFile = audioFile
        self.segments = segments
    }
}

public enum TranscriptOverlapDecisionKind: String, Codable, Equatable, Sendable {
    case duplicateRemoved
    case continuationMerged
    case keptBoth
    case uncertainConflict
    case gptRepaired
    case gptFailedFallback
}

public struct TranscriptOverlapDecision: Equatable, Sendable {
    public var kind: TranscriptOverlapDecisionKind
    public var trackID: String
    public var previousChunkSequence: Int?
    public var nextChunkSequence: Int?
    public var boundaryTime: TimeInterval
    public var reason: String

    public init(
        kind: TranscriptOverlapDecisionKind,
        trackID: String,
        previousChunkSequence: Int?,
        nextChunkSequence: Int?,
        boundaryTime: TimeInterval,
        reason: String
    ) {
        self.kind = kind
        self.trackID = trackID
        self.previousChunkSequence = previousChunkSequence
        self.nextChunkSequence = nextChunkSequence
        self.boundaryTime = boundaryTime
        self.reason = reason
    }
}

public struct TranscriptOverlapStitchResult: Equatable, Sendable {
    public var segments: [TranscriptSegment]
    public var decisions: [TranscriptOverlapDecision]

    public init(segments: [TranscriptSegment], decisions: [TranscriptOverlapDecision] = []) {
        self.segments = segments
        self.decisions = decisions
    }
}

public struct TranscriptOverlapRepairRequest: Equatable, Sendable {
    public var boundary: TranscriptOverlapBoundary
    public var contextBefore: [TranscriptSegment]
    public var previousChunkOverlapSegments: [TranscriptSegment]
    public var nextChunkOverlapSegments: [TranscriptSegment]
    public var deterministicProposal: [TranscriptSegment]
    public var contextAfter: [TranscriptSegment]

    public init(
        boundary: TranscriptOverlapBoundary,
        contextBefore: [TranscriptSegment],
        previousChunkOverlapSegments: [TranscriptSegment],
        nextChunkOverlapSegments: [TranscriptSegment],
        deterministicProposal: [TranscriptSegment],
        contextAfter: [TranscriptSegment]
    ) {
        self.boundary = boundary
        self.contextBefore = contextBefore
        self.previousChunkOverlapSegments = previousChunkOverlapSegments
        self.nextChunkOverlapSegments = nextChunkOverlapSegments
        self.deterministicProposal = deterministicProposal
        self.contextAfter = contextAfter
    }
}

public struct TranscriptOverlapBoundary: Equatable, Sendable {
    public var trackID: String
    public var previousChunkSequence: Int?
    public var nextChunkSequence: Int?
    public var boundaryTime: TimeInterval
    public var overlapSeconds: TimeInterval

    public init(
        trackID: String,
        previousChunkSequence: Int?,
        nextChunkSequence: Int?,
        boundaryTime: TimeInterval,
        overlapSeconds: TimeInterval
    ) {
        self.trackID = trackID
        self.previousChunkSequence = previousChunkSequence
        self.nextChunkSequence = nextChunkSequence
        self.boundaryTime = boundaryTime
        self.overlapSeconds = overlapSeconds
    }
}

public struct TranscriptOverlapRepairResponse: Equatable, Sendable {
    public var segments: [TranscriptSegment]
    public var conflict: Bool
    public var reason: String

    public init(segments: [TranscriptSegment], conflict: Bool, reason: String) {
        self.segments = segments
        self.conflict = conflict
        self.reason = reason
    }
}

public protocol TranscriptOverlapRepairClient: Sendable {
    func repair(_ request: TranscriptOverlapRepairRequest) async throws -> TranscriptOverlapRepairResponse
}

public struct TranscriptOverlapStitcher: Sendable {
    private let repairClient: (any TranscriptOverlapRepairClient)?
    private let maxConcurrentRepairs: Int

    public init(
        repairClient: (any TranscriptOverlapRepairClient)? = nil,
        maxConcurrentRepairs: Int = 2
    ) {
        self.repairClient = repairClient
        self.maxConcurrentRepairs = max(1, maxConcurrentRepairs)
    }

    public func stitch(transcriptions: [TranscribedAudioFile]) async -> TranscriptOverlapStitchResult {
        let sortedTranscriptions = transcriptions.sorted(by: Self.sortTranscriptions)
        let initialSegments = Self.sortSegments(sortedTranscriptions.flatMap(\.segments))
        var planningSegments = initialSegments
        var plans: [BoundaryRepairPlan] = []

        for (previous, next) in Self.adjacentOverlapPairs(sortedTranscriptions) {
            let boundary = TranscriptOverlapBoundary(
                trackID: next.audioFile.trackID,
                previousChunkSequence: previous.audioFile.sequenceNumber,
                nextChunkSequence: next.audioFile.sequenceNumber,
                boundaryTime: next.audioFile.startTimeOffset,
                overlapSeconds: next.audioFile.overlapDuration ?? previous.audioFile.overlapDuration ?? 0
            )
            guard boundary.overlapSeconds > 0 else { continue }

            let previousOverlap = Self.overlapSegments(
                previous.segments,
                boundaryTime: boundary.boundaryTime,
                overlapSeconds: boundary.overlapSeconds,
                isPreviousChunk: true
            )
            let nextOverlap = Self.overlapSegments(
                next.segments,
                boundaryTime: boundary.boundaryTime,
                overlapSeconds: boundary.overlapSeconds,
                isPreviousChunk: false
            )
            let affectedIDs = Set((previousOverlap + nextOverlap).map(\.id))
            guard !affectedIDs.isEmpty else { continue }

            let deterministic = Self.deterministicProposal(
                previousOverlap: previousOverlap,
                nextOverlap: nextOverlap,
                boundary: boundary
            )

            let request: TranscriptOverlapRepairRequest?

            if repairClient != nil {
                let contextBefore = Self.contextBefore(
                    planningSegments,
                    boundaryTime: boundary.boundaryTime,
                    excluding: affectedIDs
                )
                let contextAfter = Self.contextAfter(
                    planningSegments,
                    boundaryTime: boundary.boundaryTime + boundary.overlapSeconds,
                    excluding: affectedIDs
                )
                request = TranscriptOverlapRepairRequest(
                    boundary: boundary,
                    contextBefore: contextBefore,
                    previousChunkOverlapSegments: previousOverlap,
                    nextChunkOverlapSegments: nextOverlap,
                    deterministicProposal: deterministic.segments,
                    contextAfter: contextAfter
                )
            } else {
                request = nil
            }

            plans.append(BoundaryRepairPlan(
                index: plans.count,
                boundary: boundary,
                affectedIDs: affectedIDs,
                deterministicSegments: deterministic.segments,
                deterministicDecisions: deterministic.decisions,
                request: request
            ))

            planningSegments.removeAll { affectedIDs.contains($0.id) }
            planningSegments.append(contentsOf: deterministic.segments)
            planningSegments = Self.sortSegments(planningSegments)
        }

        let repairOutcomes: [Int: BoundaryRepairOutcome]
        if let repairClient {
            repairOutcomes = await Self.repairOutcomes(
                for: plans,
                repairClient: repairClient,
                maxConcurrentRepairs: maxConcurrentRepairs
            )
        } else {
            repairOutcomes = [:]
        }

        var currentSegments = initialSegments
        var decisions: [TranscriptOverlapDecision] = []
        for plan in plans {
            decisions.append(contentsOf: plan.deterministicDecisions)
            if let repairDecision = repairOutcomes[plan.index]?.decision {
                decisions.append(repairDecision)
            }

            let proposal = repairOutcomes[plan.index]?.segments ?? plan.deterministicSegments
            currentSegments.removeAll { plan.affectedIDs.contains($0.id) }
            currentSegments.append(contentsOf: proposal)
            currentSegments = Self.sortSegments(currentSegments)
        }

        return TranscriptOverlapStitchResult(
            segments: currentSegments,
            decisions: decisions
        )
    }

    private struct BoundaryRepairPlan: Sendable {
        var index: Int
        var boundary: TranscriptOverlapBoundary
        var affectedIDs: Set<UUID>
        var deterministicSegments: [TranscriptSegment]
        var deterministicDecisions: [TranscriptOverlapDecision]
        var request: TranscriptOverlapRepairRequest?
    }

    private struct BoundaryRepairOutcome: Sendable {
        var index: Int
        var segments: [TranscriptSegment]?
        var decision: TranscriptOverlapDecision
    }

    private static func repairOutcomes(
        for plans: [BoundaryRepairPlan],
        repairClient: any TranscriptOverlapRepairClient,
        maxConcurrentRepairs: Int
    ) async -> [Int: BoundaryRepairOutcome] {
        let repairPlans = plans.filter { $0.request != nil }
        guard !repairPlans.isEmpty else { return [:] }

        return await withTaskGroup(of: BoundaryRepairOutcome.self) { group in
            var nextPlanIndex = 0
            let initialCount = min(maxConcurrentRepairs, repairPlans.count)

            func enqueue(_ plan: BoundaryRepairPlan) {
                guard let request = plan.request else { return }

                group.addTask {
                    do {
                        let repair = try await repairClient.repair(request)
                        if repair.conflict {
                            return BoundaryRepairOutcome(
                                index: plan.index,
                                segments: nil,
                                decision: decision(.uncertainConflict, plan.boundary, repair.reason)
                            )
                        }
                        if repairIsSafe(repair.segments, boundary: plan.boundary) {
                            return BoundaryRepairOutcome(
                                index: plan.index,
                                segments: repair.segments,
                                decision: decision(.gptRepaired, plan.boundary, repair.reason)
                            )
                        }
                        return BoundaryRepairOutcome(
                            index: plan.index,
                            segments: nil,
                            decision: decision(.gptFailedFallback, plan.boundary, "repair outside overlap bounds")
                        )
                    } catch {
                        return BoundaryRepairOutcome(
                            index: plan.index,
                            segments: nil,
                            decision: decision(.gptFailedFallback, plan.boundary, String(describing: error))
                        )
                    }
                }
            }

            while nextPlanIndex < initialCount {
                enqueue(repairPlans[nextPlanIndex])
                nextPlanIndex += 1
            }

            var outcomes: [Int: BoundaryRepairOutcome] = [:]
            for await outcome in group {
                outcomes[outcome.index] = outcome
                if nextPlanIndex < repairPlans.count {
                    enqueue(repairPlans[nextPlanIndex])
                    nextPlanIndex += 1
                }
            }
            return outcomes
        }
    }

    private static func adjacentOverlapPairs(_ transcriptions: [TranscribedAudioFile]) -> [(TranscribedAudioFile, TranscribedAudioFile)] {
        var pairs: [(TranscribedAudioFile, TranscribedAudioFile)] = []
        let grouped = Dictionary(grouping: transcriptions, by: \.audioFile.trackID)
        for values in grouped.values {
            let sorted = values.sorted(by: sortTranscriptions)
            for index in sorted.indices.dropFirst() {
                let previous = sorted[sorted.index(before: index)]
                let next = sorted[index]
                let previousSequence = previous.audioFile.sequenceNumber
                let nextSequence = next.audioFile.sequenceNumber
                if previousSequence == nil || nextSequence == nil || previousSequence! + 1 == nextSequence! {
                    pairs.append((previous, next))
                }
            }
        }
        return pairs.sorted { $0.1.audioFile.startTimeOffset < $1.1.audioFile.startTimeOffset }
    }

    private static func overlapSegments(
        _ segments: [TranscriptSegment],
        boundaryTime: TimeInterval,
        overlapSeconds: TimeInterval,
        isPreviousChunk: Bool
    ) -> [TranscriptSegment] {
        let start = isPreviousChunk ? boundaryTime - 7 : boundaryTime - 1
        let end = isPreviousChunk ? boundaryTime + 1 : boundaryTime + overlapSeconds + 7
        return segments
            .filter { $0.endTime >= start && $0.startTime <= end }
            .sorted(by: sortSegments)
    }

    private static func deterministicProposal(
        previousOverlap: [TranscriptSegment],
        nextOverlap: [TranscriptSegment],
        boundary: TranscriptOverlapBoundary
    ) -> (segments: [TranscriptSegment], decisions: [TranscriptOverlapDecision]) {
        var kept = previousOverlap + nextOverlap
        var decisions: [TranscriptOverlapDecision] = []

        for next in nextOverlap {
            guard let duplicate = kept.first(where: {
                $0.id != next.id &&
                previousOverlap.map(\.id).contains($0.id) &&
                areDuplicates($0, next)
            }) else {
                continue
            }

            let preferred = preferredDuplicate(duplicate, next)
            kept.removeAll { $0.id == duplicate.id || $0.id == next.id }
            kept.append(preferred)
            decisions.append(decision(.duplicateRemoved, boundary, "duplicate overlap text"))
        }

        if let previous = kept
            .filter({ previousOverlap.map(\.id).contains($0.id) })
            .sorted(by: sortSegments)
            .last,
           let next = kept
            .filter({ nextOverlap.map(\.id).contains($0.id) })
            .sorted(by: sortSegments)
            .first,
           shouldMergeContinuation(previous, next) {
            let merged = mergeContinuation(previous, next)
            kept.removeAll { $0.id == previous.id || $0.id == next.id }
            kept.append(merged)
            decisions.append(decision(.continuationMerged, boundary, "clipped boundary continuation"))
        }

        if decisions.isEmpty {
            decisions.append(decision(.keptBoth, boundary, "no duplicate or clipped boundary detected"))
        }

        return (sortSegments(kept), decisions)
    }

    private static func areDuplicates(_ lhs: TranscriptSegment, _ rhs: TranscriptSegment) -> Bool {
        let lhsTokens = normalizedTokens(lhs.text)
        let rhsTokens = normalizedTokens(rhs.text)
        guard !lhsTokens.isEmpty, !rhsTokens.isEmpty else { return false }
        if lhsTokens == rhsTokens { return true }

        let intersection = Set(lhsTokens).intersection(Set(rhsTokens)).count
        let union = Set(lhsTokens).union(Set(rhsTokens)).count
        let jaccard = union == 0 ? 0 : Double(intersection) / Double(union)
        let timeOverlap = min(lhs.endTime, rhs.endTime) - max(lhs.startTime, rhs.startTime)
        return jaccard >= 0.82 && timeOverlap >= -0.75
    }

    private static func preferredDuplicate(_ lhs: TranscriptSegment, _ rhs: TranscriptSegment) -> TranscriptSegment {
        let lhsScore = duplicateScore(lhs)
        let rhsScore = duplicateScore(rhs)
        return rhsScore > lhsScore ? rhs : lhs
    }

    private static func duplicateScore(_ segment: TranscriptSegment) -> Double {
        Double(normalizedTokens(segment.text).count) + (segment.confidence ?? 0) + max(0, segment.endTime - segment.startTime) * 0.05
    }

    private static func shouldMergeContinuation(_ previous: TranscriptSegment, _ next: TranscriptSegment) -> Bool {
        guard previous.speakerLabel == next.speakerLabel else { return false }
        let previousText = previous.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextText = next.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !previousText.isEmpty, !nextText.isEmpty else { return false }

        if overlappingTokenCount(previousText, nextText) > 0 {
            return true
        }
        if previousText.rangeOfCharacter(from: CharacterSet(charactersIn: ".?!")) == nil {
            return true
        }
        return nextText.first?.isLowercase == true
    }

    private static func mergeContinuation(_ previous: TranscriptSegment, _ next: TranscriptSegment) -> TranscriptSegment {
        let overlapCount = overlappingTokenCount(previous.text, next.text)
        let previousWords = previous.text.split(separator: " ").map(String.init)
        let nextWords = next.text.split(separator: " ").map(String.init)
        let mergedWords = previousWords + nextWords.dropFirst(overlapCount)
        return TranscriptSegment(
            speakerLabel: previous.speakerLabel,
            text: mergedWords.joined(separator: " "),
            startTime: min(previous.startTime, next.startTime),
            endTime: max(previous.endTime, next.endTime),
            confidence: averagedConfidence(previous.confidence, next.confidence)
        )
    }

    private static func overlappingTokenCount(_ previous: String, _ next: String) -> Int {
        let previousTokens = normalizedTokens(previous)
        let nextTokens = normalizedTokens(next)
        guard !previousTokens.isEmpty, !nextTokens.isEmpty else { return 0 }
        let maxCount = min(previousTokens.count, nextTokens.count)
        for count in stride(from: maxCount, through: 1, by: -1) {
            if Array(previousTokens.suffix(count)) == Array(nextTokens.prefix(count)) {
                return count
            }
        }
        return 0
    }

    private static func normalizedTokens(_ text: String) -> [String] {
        let allowed = CharacterSet.alphanumerics.union(.whitespacesAndNewlines)
        let scalars = text.lowercased().unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : " "
        }
        return String(scalars)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    private static func repairIsSafe(_ segments: [TranscriptSegment], boundary: TranscriptOverlapBoundary) -> Bool {
        let lowerBound = boundary.boundaryTime - 7
        let upperBound = boundary.boundaryTime + boundary.overlapSeconds + 7
        return segments.allSatisfy {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            $0.startTime >= lowerBound &&
            $0.endTime <= upperBound &&
            $0.endTime >= $0.startTime
        }
    }

    private static func contextBefore(
        _ segments: [TranscriptSegment],
        boundaryTime: TimeInterval,
        excluding affectedIDs: Set<UUID>
    ) -> [TranscriptSegment] {
        Array(sortSegments(segments)
            .filter { !affectedIDs.contains($0.id) && $0.endTime <= boundaryTime }
            .suffix(3))
    }

    private static func contextAfter(
        _ segments: [TranscriptSegment],
        boundaryTime: TimeInterval,
        excluding affectedIDs: Set<UUID>
    ) -> [TranscriptSegment] {
        Array(sortSegments(segments)
            .filter { !affectedIDs.contains($0.id) && $0.startTime >= boundaryTime }
            .prefix(3))
    }

    private static func decision(
        _ kind: TranscriptOverlapDecisionKind,
        _ boundary: TranscriptOverlapBoundary,
        _ reason: String
    ) -> TranscriptOverlapDecision {
        TranscriptOverlapDecision(
            kind: kind,
            trackID: boundary.trackID,
            previousChunkSequence: boundary.previousChunkSequence,
            nextChunkSequence: boundary.nextChunkSequence,
            boundaryTime: boundary.boundaryTime,
            reason: reason
        )
    }

    private static func sortTranscriptions(_ lhs: TranscribedAudioFile, _ rhs: TranscribedAudioFile) -> Bool {
        if lhs.audioFile.trackID != rhs.audioFile.trackID {
            return lhs.audioFile.trackID < rhs.audioFile.trackID
        }
        if lhs.audioFile.startTimeOffset != rhs.audioFile.startTimeOffset {
            return lhs.audioFile.startTimeOffset < rhs.audioFile.startTimeOffset
        }
        return (lhs.audioFile.sequenceNumber ?? 0) < (rhs.audioFile.sequenceNumber ?? 0)
    }

    private static func sortSegments(_ lhs: TranscriptSegment, _ rhs: TranscriptSegment) -> Bool {
        if lhs.startTime != rhs.startTime {
            return lhs.startTime < rhs.startTime
        }
        if lhs.endTime != rhs.endTime {
            return lhs.endTime < rhs.endTime
        }
        return lhs.text < rhs.text
    }

    private static func sortSegments(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.sorted(by: sortSegments)
    }

    private static func averagedConfidence(_ lhs: Double?, _ rhs: Double?) -> Double? {
        switch (lhs, rhs) {
        case (.some(let lhs), .some(let rhs)):
            (lhs + rhs) / 2
        case (.some(let value), .none), (.none, .some(let value)):
            value
        case (.none, .none):
            nil
        }
    }
}
