import BarnOwlCore
import Foundation
import SwiftUI

enum BarnOwlAnimationFrames {
    static let count = 24

    static func imageName(for frame: Int) -> String {
        let normalized = ((frame % count) + count) % count
        return String(format: "BarnOwlFrame%02d", normalized)
    }
}

enum BarnOwlDesign {
    static let amber = Color(red: 0.86, green: 0.53, blue: 0.13)
    static let amberLight = Color(red: 1.0, green: 0.73, blue: 0.36)
    static let clay = Color(red: 0.53, green: 0.31, blue: 0.16)
    static let cream = Color(red: 0.97, green: 0.91, blue: 0.80)
    static let graphite = Color(red: 0.12, green: 0.13, blue: 0.13)
    static let graphiteRaised = Color(red: 0.18, green: 0.19, blue: 0.18)
    static let moss = Color(red: 0.39, green: 0.50, blue: 0.43)
    static let warmPanel = Color(nsColor: .controlBackgroundColor).opacity(0.80)
    static let warmField = Color(nsColor: .textBackgroundColor).opacity(0.82)
    static let warmStroke = Color.primary.opacity(0.08)
    static let softShadow = Color.black.opacity(0.08)
    static let darkStroke = Color.white.opacity(0.10)

    static var windowBackground: LinearGradient {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor),
                amber.opacity(0.07),
                graphite.opacity(0.025),
                moss.opacity(0.045)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var darkPopoverBackground: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.10, green: 0.11, blue: 0.11),
                Color(red: 0.15, green: 0.16, blue: 0.15),
                Color(red: 0.12, green: 0.12, blue: 0.11)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct BarnOwlMenuBarIcon: View {
    var status: RecordingStatus
    var firstRecordingPause: ClosedRange<UInt64> = 300_000_000 ... 800_000_000
    var recordingPause: ClosedRange<UInt64> = 25_000_000_000 ... 35_000_000_000
    var nonRecordingPause: ClosedRange<UInt64> = 720_000_000_000 ... 1_080_000_000_000

    @State private var animationFrame = 0
    @State private var hasPlayedRecordingAnimation = false

    var body: some View {
        BarnOwlMark(
            status: status,
            animationFrame: animationFrame
        )
        .accessibilityLabel("Barn Owl \(status.displayName)")
        .task(id: status) {
            await runAnimationLoop()
        }
    }

    @MainActor
    private func runAnimationLoop() async {
        animationFrame = 0
        hasPlayedRecordingAnimation = false

        while !Task.isCancelled {
            let pause: UInt64
            if status == .recording {
                pause = hasPlayedRecordingAnimation
                    ? UInt64.random(in: recordingPause)
                    : UInt64.random(in: firstRecordingPause)
            } else {
                pause = UInt64.random(in: nonRecordingPause)
            }
            try? await Task.sleep(nanoseconds: pause)

            hasPlayedRecordingAnimation = true
            await playAmbientSequence()
        }
    }

    @MainActor
    private func playAmbientSequence() async {
        for frame in 0 ..< BarnOwlAnimationFrames.count {
            animationFrame = frame
            try? await Task.sleep(nanoseconds: 180_000_000)
        }
        animationFrame = 0
    }
}

struct BarnOwlMark: View {
    var status: RecordingStatus
    var animationFrame: Int = 0
    var headTurn: Double = 0
    var blink = false
    var earWiggle: Double = 0
    var badge = true

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)

            ZStack {
                statusHalo
                    .frame(width: size * 0.94, height: size * 0.94)

                owlBody(size: size)

                if status == .recording {
                    Circle()
                        .fill(.red)
                        .frame(width: size * 0.16, height: size * 0.16)
                        .offset(x: size * 0.32, y: -size * 0.32)
                        .shadow(color: .red.opacity(0.55), radius: size * 0.05)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func owlBody(size: CGFloat) -> some View {
        Image(BarnOwlAnimationFrames.imageName(for: animationFrame))
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .rotation3DEffect(
                .degrees(headTurn * 11),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.45
            )
            .rotationEffect(.degrees(headTurn * 4.5))
            .offset(x: CGFloat(headTurn) * size * 0.018, y: abs(CGFloat(headTurn)) * size * 0.004)
            .scaleEffect(x: 1 - abs(CGFloat(headTurn)) * 0.025, y: 1, anchor: .center)
            .shadow(color: .black.opacity(badge ? 0.16 : 0), radius: size * 0.07, y: size * 0.025)
    }

    private func animatedEyes(size: CGFloat) -> some View {
        HStack(spacing: size * 0.02) {
            animatedEye(size: size)
            animatedEye(size: size)
        }
        .offset(y: -size * 0.075)
    }

    private func animatedEye(size: CGFloat) -> some View {
        let eyeSize = size * 0.245
        let pupilSize = size * 0.106
        let gazeOffset = CGFloat(headTurn) * size * 0.044

        return ZStack {
            Circle()
                .fill(BarnOwlDesign.cream)
                .overlay(
                    Circle()
                        .stroke(BarnOwlDesign.clay.opacity(0.50), lineWidth: max(0.7, size * 0.018))
                )
                .shadow(color: .black.opacity(0.10), radius: size * 0.012, y: size * 0.004)

            if blink {
                ClosedOwlEyelidShape()
                    .fill(
                        LinearGradient(
                            colors: [
                                BarnOwlDesign.amberLight.opacity(0.94),
                                BarnOwlDesign.cream,
                                BarnOwlDesign.clay.opacity(0.36)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        ClosedOwlEyelidShape()
                            .stroke(BarnOwlDesign.clay.opacity(0.70), lineWidth: max(0.8, size * 0.015))
                    )
                    .transition(.opacity)
            } else {
                Circle()
                    .fill(Color(red: 0.035, green: 0.032, blue: 0.028))
                    .frame(width: pupilSize, height: pupilSize)
                    .overlay(
                        Circle()
                            .fill(.white.opacity(0.90))
                            .frame(width: pupilSize * 0.34, height: pupilSize * 0.34)
                            .offset(x: -pupilSize * 0.16, y: -pupilSize * 0.18)
                    )
                    .offset(x: gazeOffset)
                    .animation(.easeInOut(duration: 0.12), value: headTurn)
            }
        }
        .frame(width: eyeSize, height: eyeSize)
        .clipped()
    }

    private func earWiggleOverlay(size: CGFloat, side: OwlFacePatchSide) -> some View {
        OwlEarTwitchShape(side: side)
            .fill(
                LinearGradient(
                    colors: [
                        BarnOwlDesign.amberLight.opacity(0.60),
                        BarnOwlDesign.clay.opacity(0.48)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: size * 0.20, height: size * 0.22)
            .rotationEffect(.degrees((side == .left ? -1 : 1) * (7 + earWiggle * 8)))
            .offset(
                x: (side == .left ? -1 : 1) * size * (0.285 + abs(earWiggle) * 0.008),
                y: -size * (0.355 + max(0, earWiggle) * 0.018)
            )
            .opacity(abs(earWiggle) > 0.01 ? 0.68 : 0)
    }

    @ViewBuilder
    private var statusHalo: some View {
        switch status {
        case .recording:
            Circle()
                .fill(.red.opacity(0.15))
                .scaleEffect(blink ? 1.12 : 0.92)
        case .processing:
            Circle()
                .fill(BarnOwlDesign.moss.opacity(0.2))
                .scaleEffect(blink ? 1.04 : 0.96)
        case .failed:
            Circle()
                .fill(BarnOwlDesign.amber.opacity(0.22))
        case .idle, .preparing:
            EmptyView()
        }
    }

}

private struct ClosedOwlEyelidShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = rect.width
        let height = rect.height

        path.move(to: CGPoint(x: rect.minX + width * 0.06, y: rect.midY + height * 0.03))
        path.addCurve(
            to: CGPoint(x: rect.maxX - width * 0.06, y: rect.midY + height * 0.03),
            control1: CGPoint(x: rect.minX + width * 0.26, y: rect.midY - height * 0.15),
            control2: CGPoint(x: rect.maxX - width * 0.26, y: rect.midY - height * 0.15)
        )
        path.addCurve(
            to: CGPoint(x: rect.minX + width * 0.06, y: rect.midY + height * 0.03),
            control1: CGPoint(x: rect.maxX - width * 0.24, y: rect.midY + height * 0.19),
            control2: CGPoint(x: rect.minX + width * 0.24, y: rect.midY + height * 0.19)
        )
        path.closeSubpath()
        return path
    }
}

private struct OwlHeadShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let minX = rect.minX
        let maxX = rect.maxX
        let minY = rect.minY
        let maxY = rect.maxY
        let width = rect.width
        let height = rect.height

        path.move(to: CGPoint(x: minX + width * 0.16, y: minY + height * 0.36))
        path.addLine(to: CGPoint(x: minX + width * 0.22, y: minY + height * 0.08))
        path.addLine(to: CGPoint(x: minX + width * 0.39, y: minY + height * 0.24))
        path.addCurve(
            to: CGPoint(x: minX + width * 0.61, y: minY + height * 0.24),
            control1: CGPoint(x: minX + width * 0.46, y: minY + height * 0.18),
            control2: CGPoint(x: minX + width * 0.54, y: minY + height * 0.18)
        )
        path.addLine(to: CGPoint(x: minX + width * 0.78, y: minY + height * 0.08))
        path.addLine(to: CGPoint(x: minX + width * 0.84, y: minY + height * 0.36))
        path.addCurve(
            to: CGPoint(x: minX + width * 0.5, y: maxY - height * 0.05),
            control1: CGPoint(x: maxX, y: minY + height * 0.58),
            control2: CGPoint(x: minX + width * 0.82, y: maxY - height * 0.05)
        )
        path.addCurve(
            to: CGPoint(x: minX + width * 0.16, y: minY + height * 0.36),
            control1: CGPoint(x: minX + width * 0.18, y: maxY - height * 0.05),
            control2: CGPoint(x: minX, y: minY + height * 0.58)
        )
        path.closeSubpath()
        return path
    }
}

private enum OwlFacePatchSide {
    case left
    case right
}

private struct OwlEarTwitchShape: Shape {
    var side: OwlFacePatchSide

    func path(in rect: CGRect) -> Path {
        let mirrored = side == .right
        func x(_ value: CGFloat) -> CGFloat {
            mirrored ? rect.maxX - rect.width * value : rect.minX + rect.width * value
        }

        var path = Path()
        path.move(to: CGPoint(x: x(0.10), y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: x(0.76), y: rect.minY + rect.height * 0.08),
            control1: CGPoint(x: x(0.18), y: rect.minY + rect.height * 0.52),
            control2: CGPoint(x: x(0.42), y: rect.minY + rect.height * 0.12)
        )
        path.addCurve(
            to: CGPoint(x: x(0.90), y: rect.maxY - rect.height * 0.10),
            control1: CGPoint(x: x(0.90), y: rect.minY + rect.height * 0.34),
            control2: CGPoint(x: x(1.02), y: rect.minY + rect.height * 0.72)
        )
        path.addCurve(
            to: CGPoint(x: x(0.10), y: rect.maxY),
            control1: CGPoint(x: x(0.64), y: rect.maxY + rect.height * 0.03),
            control2: CGPoint(x: x(0.32), y: rect.maxY + rect.height * 0.03)
        )
        path.closeSubpath()
        return path
    }
}

private struct OwlFacePatchShape: Shape {
    var side: OwlFacePatchSide

    func path(in rect: CGRect) -> Path {
        let mirrored = side == .right
        let minX = rect.minX
        let maxX = rect.maxX
        let minY = rect.minY
        let maxY = rect.maxY
        let width = rect.width
        let height = rect.height
        func x(_ value: CGFloat) -> CGFloat {
            mirrored ? maxX - width * value : minX + width * value
        }

        var path = Path()
        path.move(to: CGPoint(x: x(0.92), y: minY + height * 0.18))
        path.addCurve(
            to: CGPoint(x: x(0.16), y: minY + height * 0.30),
            control1: CGPoint(x: x(0.72), y: minY + height * 0.02),
            control2: CGPoint(x: x(0.30), y: minY + height * 0.06)
        )
        path.addCurve(
            to: CGPoint(x: x(0.22), y: maxY - height * 0.18),
            control1: CGPoint(x: x(0.00), y: minY + height * 0.55),
            control2: CGPoint(x: x(0.06), y: maxY - height * 0.10)
        )
        path.addCurve(
            to: CGPoint(x: x(0.94), y: maxY - height * 0.08),
            control1: CGPoint(x: x(0.46), y: maxY - height * 0.02),
            control2: CGPoint(x: x(0.78), y: maxY - height * 0.02)
        )
        path.addCurve(
            to: CGPoint(x: x(0.92), y: minY + height * 0.18),
            control1: CGPoint(x: x(1.02), y: maxY - height * 0.35),
            control2: CGPoint(x: x(1.00), y: minY + height * 0.38)
        )
        path.closeSubpath()
        return path
    }
}

private struct BeakShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

private struct OwlWingShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.18))
        path.addQuadCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY),
            control: CGPoint(x: rect.minX + rect.width * 0.22, y: rect.maxY)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.18),
            control: CGPoint(x: rect.maxX - rect.width * 0.22, y: rect.maxY)
        )
        return path
    }
}

extension RecordingStatus {
    var displayName: String {
        switch self {
        case .idle: "Ready"
        case .preparing: "Preparing"
        case .recording: "Recording"
        case .processing: "Processing"
        case .failed: "Needs Attention"
        }
    }

    var tint: Color {
        switch self {
        case .idle: .secondary
        case .preparing: BarnOwlDesign.amberLight
        case .recording: .red
        case .processing: BarnOwlDesign.moss
        case .failed: BarnOwlDesign.amber
        }
    }

    fileprivate var bodyFill: Color {
        switch self {
        case .recording:
            Color(red: 0.47, green: 0.28, blue: 0.15)
        case .processing:
            Color(red: 0.34, green: 0.40, blue: 0.36)
        case .failed:
            Color(red: 0.70, green: 0.37, blue: 0.15)
        case .idle, .preparing:
            Color(red: 0.54, green: 0.36, blue: 0.21)
        }
    }

    fileprivate var bodyHighlight: Color {
        switch self {
        case .recording:
            Color(red: 0.72, green: 0.45, blue: 0.23)
        case .processing:
            Color(red: 0.52, green: 0.60, blue: 0.53)
        case .failed:
            BarnOwlDesign.amberLight
        case .idle, .preparing:
            Color(red: 0.74, green: 0.52, blue: 0.30)
        }
    }

    var rotationDegrees: Double {
        switch self {
        case .recording:
            2
        case .processing:
            4
        case .preparing:
            3
        case .idle, .failed:
            1.5
        }
    }

}
