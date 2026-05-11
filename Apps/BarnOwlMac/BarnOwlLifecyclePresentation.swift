import BarnOwlCore
import SwiftUI

enum BarnOwlLifecyclePhase: Equatable {
    case ready
    case preparing
    case recording
    case stopping
    case processing
    case complete
    case needsAttention
}

struct BarnOwlLifecyclePresentation: Equatable {
    var phase: BarnOwlLifecyclePhase
    var title: String
    var detail: String
    var systemImage: String

    var tint: Color {
        switch phase {
        case .ready, .complete:
            BarnOwlDesign.moss
        case .preparing, .stopping, .processing:
            BarnOwlDesign.amber
        case .recording:
            .red
        case .needsAttention:
            .red
        }
    }

    static func make(
        state: RecordingLifecycleState,
        hasActiveProcessing: Bool,
        hasFailedProcessing: Bool = false,
        hasDisplayedNote: Bool
    ) -> BarnOwlLifecyclePresentation {
        switch state {
        case .idle, .ready:
            return BarnOwlLifecyclePresentation(
                phase: .ready,
                title: "Ready",
                detail: "Ready to capture the next meeting.",
                systemImage: "mic.circle"
            )
        case .checkingPermissions, .requestingPermissions, .preparing:
            return BarnOwlLifecyclePresentation(
                phase: .preparing,
                title: "Preparing",
                detail: "Checking setup and starting audio capture.",
                systemImage: "hourglass"
            )
        case .recording:
            return BarnOwlLifecyclePresentation(
                phase: .recording,
                title: "Recording",
                detail: "Capturing microphone and system audio.",
                systemImage: "record.circle.fill"
            )
        case .stopping:
            return BarnOwlLifecyclePresentation(
                phase: .stopping,
                title: "Stopping",
                detail: "Flushing audio and closing realtime preview.",
                systemImage: "stop.circle"
            )
        case .processing:
            return BarnOwlLifecyclePresentation(
                phase: .processing,
                title: "Processing",
                detail: "Generating the final transcript and meeting notes.",
                systemImage: "waveform.badge.magnifyingglass"
            )
        case .completed:
            if hasFailedProcessing {
                return BarnOwlLifecyclePresentation(
                    phase: .needsAttention,
                    title: "Needs Attention",
                    detail: "Final processing needs a retry.",
                    systemImage: "exclamationmark.triangle.fill"
                )
            }
            return BarnOwlLifecyclePresentation(
                phase: hasActiveProcessing ? .processing : (hasDisplayedNote ? .complete : .ready),
                title: hasActiveProcessing ? "Processing" : (hasDisplayedNote ? "Complete" : "Ready"),
                detail: hasActiveProcessing
                    ? "Final transcript and notes are running in the background."
                    : "Meeting notes are ready in the local library.",
                systemImage: hasActiveProcessing ? "clock.arrow.circlepath" : "checkmark.circle.fill"
            )
        case .failed(let failure):
            return BarnOwlLifecyclePresentation(
                phase: .needsAttention,
                title: "Needs Attention",
                detail: failure.message,
                systemImage: "exclamationmark.triangle.fill"
            )
        }
    }

    static func primaryActionTitle(for state: RecordingLifecycleState) -> String {
        if state.canStopRecording {
            return "Stop Recording"
        }

        if state.canStartRecording {
            return "Start Recording"
        }

        switch state {
        case .checkingPermissions, .requestingPermissions, .preparing:
            return "Preparing..."
        case .stopping:
            return "Stopping..."
        case .processing:
            return "Processing..."
        case .idle, .ready, .recording, .completed, .failed:
            return "Start Recording"
        }
    }
}
