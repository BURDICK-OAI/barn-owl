import AppKit
import BarnOwlCore
import Combine
import SwiftUI

@MainActor
final class BarnOwlStatusBarController: NSObject {
    private let model: BarnOwlAppModel
    private let openRecorder: () -> Void
    private let openSettings: () -> Void
    private let quit: () -> Void
    private let statusItem = NSStatusBar.system.statusItem(withLength: RecordingStatus.fixedStatusItemLength)
    private let popover = NSPopover()
    private var cancellables: Set<AnyCancellable> = []
    private var ambientAnimationTimer: Timer?
    private var animationFrameTimer: Timer?
    private var ambientAnimationFramesRemaining = 0
    private var animationPhase = 0
    private var hasPlayedRecordingAnimation = false
    private var iconCache: [StatusIconCacheKey: NSImage] = [:]

    init(
        model: BarnOwlAppModel,
        openRecorder: @escaping () -> Void,
        openSettings: @escaping () -> Void,
        quit: @escaping () -> Void
    ) {
        self.model = model
        self.openRecorder = openRecorder
        self.openSettings = openSettings
        self.quit = quit
        super.init()

        configureStatusItem()
        configurePopover()
        observeModel()
        scheduleAmbientAnimation()
        updateStatusItem()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover)
        button.imagePosition = .imageLeft
        button.toolTip = "Barn Owl"
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = preferredPopoverContentSize
        popover.delegate = self
    }

    private func makePopoverContentViewController() -> NSViewController {
        NSHostingController(
            rootView: MenuBarView(
                model: model,
                openRecorder: { [weak self] in
                    self?.popover.performClose(nil)
                    self?.openRecorder()
                },
                openSettings: { [weak self] in
                    self?.popover.performClose(nil)
                    self?.openSettings()
                },
                quit: { [weak self] in
                    self?.quit()
                }
            )
            .frame(width: preferredPopoverContentSize.width)
        )
    }

    private func observeModel() {
        model.$status
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.hasPlayedRecordingAnimation = false
                self.stopAmbientAnimation(updateStatusItem: false)
                self.scheduleAmbientAnimation()
                self.updateStatusItem()
                self.updatePopoverSizeIfNeeded()
            }
            .store(in: &cancellables)

        model.$liveTranscriptPreview
            .removeDuplicates()
            .debounce(for: .milliseconds(750), scheduler: RunLoop.main)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItemTooltip()
            }
            .store(in: &cancellables)

        Publishers.MergeMany(
            model.$recentSessions.map { _ in () }.eraseToAnyPublisher(),
            model.$lastError.map { _ in () }.eraseToAnyPublisher(),
            model.$progressFraction.map { _ in () }.eraseToAnyPublisher(),
            model.$isUpdateInFlight.map { _ in () }.eraseToAnyPublisher()
        )
        .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
        .sink { [weak self] _ in
            guard let self, !self.shouldFreezePopoverSizeForTransientUpdates else { return }
            self.updatePopoverSizeIfNeeded()
        }
        .store(in: &cancellables)
    }

    private func scheduleAmbientAnimation() {
        ambientAnimationTimer?.invalidate()
        ambientAnimationTimer = Timer.scheduledTimer(withTimeInterval: nextAmbientAnimationDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.startAmbientAnimation()
            }
        }
    }

    private func startAmbientAnimation() {
        guard animationFrameTimer == nil else { return }
        ambientAnimationFramesRemaining = BarnOwlAnimationFrames.count
        if model.status == .recording {
            hasPlayedRecordingAnimation = true
        }
        animationPhase = 0
        animationFrameTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.advanceAmbientAnimationFrame()
            }
        }
    }

    private func advanceAmbientAnimationFrame() {
        animationPhase += 1
        ambientAnimationFramesRemaining -= 1
        updateStatusItem()

        guard ambientAnimationFramesRemaining <= 0 else { return }
        stopAmbientAnimation()
        scheduleAmbientAnimation()
    }

    private func stopAmbientAnimation(updateStatusItem shouldUpdateStatusItem: Bool = true) {
        ambientAnimationTimer?.invalidate()
        ambientAnimationTimer = nil
        animationFrameTimer?.invalidate()
        animationFrameTimer = nil
        ambientAnimationFramesRemaining = 0
        animationPhase = 0
        if shouldUpdateStatusItem {
            updateStatusItem()
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let status = model.status
        let cacheKey = StatusIconCacheKey(status: status, animationPhase: animationPhase)
        if let cachedImage = iconCache[cacheKey] {
            button.image = cachedImage
        } else {
            let image = BarnOwlStatusIconRenderer.image(
                status: status,
                animationPhase: animationPhase
            )
            iconCache[cacheKey] = image
            button.image = image
        }
        button.title = ""
        updateStatusItemTooltip()
        statusItem.length = RecordingStatus.fixedStatusItemLength
    }

    private func updateStatusItemTooltip() {
        guard let button = statusItem.button else { return }
        button.toolTip = "Barn Owl: \(model.lifecyclePresentation.title). \(model.lifecyclePresentation.detail)"
    }

    @objc
    private func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            updateStatusItem()
            popover.contentSize = preferredPopoverContentSize
            popover.contentViewController = makePopoverContentViewController()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func updatePopoverSizeIfNeeded(allowRecordingResize: Bool = false) {
        guard popover.isShown else { return }
        if shouldFreezePopoverSizeForTransientUpdates {
            return
        }
        guard model.status != .recording else { return }
        let size = preferredPopoverContentSize
        let widthChanged = abs(popover.contentSize.width - size.width) > 0.5
        let heightChanged = abs(popover.contentSize.height - size.height) > 0.5
        guard widthChanged || heightChanged else {
            return
        }
        popover.contentSize = size
        if widthChanged {
            popover.contentViewController = makePopoverContentViewController()
        } else {
            popover.contentViewController?.view.frame.size = size
        }
    }

    private var preferredPopoverContentSize: NSSize {
        let width: CGFloat = 420
        var height: CGFloat = 0
        let setupNeeded = BarnOwlFirstRunReadiness.currentSnapshot().menuBarSetupNeeded

        height += 74 // Header.
        if BarnOwlMenuBarPresentation.shouldShowWaveform(
            status: model.status,
            progressFraction: model.progressFraction,
            processingTimelineItems: model.processingTimelineItems
        ) {
            height += 48
        }
        if setupNeeded {
            height += 104
        } else if BarnOwlMenuBarPresentation.shouldShowTranscriptCard(
            status: model.status,
            liveTranscriptPreview: model.liveTranscriptPreview
        ) {
            height += model.status == .recording ? 118 : 94
        }

        if BarnOwlMenuBarPresentation.shouldShowStatusAndProgressCard(
            status: model.status,
            captureStatus: model.captureStatus,
            realtimeStatus: model.realtimeStatus,
            progressFraction: model.progressFraction,
            isUpdateInFlight: model.isUpdateInFlight,
            updateStatus: model.updateStatus,
            hasProcessingTimeline: false,
            hasPerformanceSummary: false,
            hasVisibleActivity: model.status != .idle && !model.visibleActivityItems.isEmpty
        ) {
            switch model.status {
            case .idle:
                height += 72
            case .preparing, .processing:
                height += 64
            case .recording:
                height += model.visibleActivityItems.isEmpty ? 138 : 176
            case .failed:
                height += 102
            }
        }

        if model.lastError != nil {
            height += 96
        }

        height += 42 // Primary action row.

        let recentCount = model.quickAccessSessions.count
        if BarnOwlMenuBarPresentation.shouldShowSessionsCard(
            quickAccessCount: recentCount,
            status: model.status,
            setupNeeded: setupNeeded
        ) {
            height += recentCount == 0 ? 72 : min(176, 54 + CGFloat(recentCount) * 72)
        }

        height += 26 // Footer.
        height += 56 // Padding and stack spacing.

        return NSSize(width: width, height: min(max(height, 300), 620))
    }

    private var shouldFreezePopoverSizeForTransientUpdates: Bool {
        switch model.status {
        case .recording, .preparing, .processing:
            return true
        case .idle, .failed:
            break
        }

        if model.progressFraction != nil {
            return true
        }

        let processingText = [model.captureStatus, model.realtimeStatus, model.updateStatus]
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return processingText.contains("processing")
            || processingText.contains("transcript")
            || processingText.contains("final")
            || processingText.contains("job")
    }

    private var nextAmbientAnimationDelay: TimeInterval {
        switch model.status {
        case .recording:
            hasPlayedRecordingAnimation ? .random(in: 25 ... 35) : .random(in: 0.3 ... 0.8)
        case .preparing, .processing:
            .random(in: 45 ... 75)
        case .idle, .failed:
            Self.randomIdleAmbientAnimationDelay
        }
    }

    private static var randomIdleAmbientAnimationDelay: TimeInterval {
        .random(in: 12 * 60 ... 18 * 60)
    }
}

extension BarnOwlStatusBarController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }
}

private struct StatusIconCacheKey: Hashable {
    var status: RecordingStatus
    var animationPhase: Int
}

private struct BarnOwlAnimationPose {
    static let frameCount = 24

    var turn: Double = 0
    var blink = false
    var earLift: Double = 0

    static func pose(for phase: Int) -> BarnOwlAnimationPose {
        switch phase {
        case 1:
            BarnOwlAnimationPose(turn: -0.45)
        case 2, 3:
            BarnOwlAnimationPose(turn: -1)
        case 4:
            BarnOwlAnimationPose(turn: 0)
        case 5:
            BarnOwlAnimationPose(turn: 0.55)
        case 6, 7:
            BarnOwlAnimationPose(turn: 1)
        case 8:
            BarnOwlAnimationPose(turn: 0.20)
        case 9:
            BarnOwlAnimationPose(blink: true)
        case 10:
            BarnOwlAnimationPose(earLift: 1)
        case 11:
            BarnOwlAnimationPose(earLift: -0.55)
        case 12:
            BarnOwlAnimationPose(earLift: 0.30)
        case 13:
            BarnOwlAnimationPose(turn: -0.35, earLift: 0.20)
        case 14:
            BarnOwlAnimationPose(turn: 0.40)
        case 15:
            BarnOwlAnimationPose(blink: true)
        case 16:
            BarnOwlAnimationPose(turn: 0.12)
        case 17:
            BarnOwlAnimationPose()
        case 18:
            BarnOwlAnimationPose(turn: -0.70)
        case 19:
            BarnOwlAnimationPose(turn: -0.15)
        case 20:
            BarnOwlAnimationPose(turn: 0.75)
        case 21:
            BarnOwlAnimationPose(turn: 0, blink: true)
        case 22:
            BarnOwlAnimationPose(earLift: 0.80)
        case 23:
            BarnOwlAnimationPose()
        default:
            BarnOwlAnimationPose()
        }
    }
}

private enum StatusOwlEarSide {
    case left
    case right
}

private enum BarnOwlStatusIconRenderer {
    static func image(status: RecordingStatus, animationPhase: Int) -> NSImage {
        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size)
        image.lockFocus()
        draw(status: status, animationPhase: animationPhase, in: CGRect(origin: .zero, size: size))
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private static func draw(status: RecordingStatus, animationPhase: Int, in rect: CGRect) {
        if drawAnimationFrameAsset(status: status, animationPhase: animationPhase, in: rect) {
            return
        }

        let pose = BarnOwlAnimationPose.pose(for: animationPhase)

        if drawLogoAsset(status: status, pose: pose, in: rect) {
            return
        }

        let size = min(rect.width, rect.height)
        let turn = pose.turn
        let shouldBlink = pose.blink

        NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 0.8, dy: 0.8)).fill()
        NSColor(calibratedWhite: 1, alpha: 0.12).setStroke()
        let badge = NSBezierPath(ovalIn: rect.insetBy(dx: 0.8, dy: 0.8))
        badge.lineWidth = 0.7
        badge.stroke()

        if status != .idle {
            let haloRect = rect.insetBy(dx: 1.5, dy: 1.5)
            status.haloColor.setFill()
            NSBezierPath(ovalIn: haloRect).fill()
        }

        let headRect = rect.insetBy(dx: size * 0.18, dy: size * 0.15)
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: rect.midX, yBy: rect.midY)
        transform.rotate(byDegrees: turn * status.rotationDegrees)
        transform.translateX(by: -rect.midX, yBy: -rect.midY)
        transform.concat()

        let head = owlHeadPath(in: headRect)
        status.owlFill.setFill()
        head.fill()
        NSColor(calibratedWhite: 0, alpha: 0.22).setStroke()
        head.lineWidth = 1
        head.stroke()

        drawFacePatches(size: size, rect: rect)
        drawEye(center: CGPoint(x: rect.minX + size * 0.40, y: rect.minY + size * 0.53), size: size, pupilOffset: turn, blink: shouldBlink)
        drawEye(center: CGPoint(x: rect.minX + size * 0.60, y: rect.minY + size * 0.53), size: size, pupilOffset: turn, blink: shouldBlink)
        drawBeak(size: size, rect: rect)
        drawWing(size: size, rect: rect)
        NSGraphicsContext.restoreGraphicsState()

        if status == .recording {
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: CGRect(x: rect.maxX - 6, y: rect.maxY - 7, width: 5, height: 5)).fill()
        }
    }

    private static func drawAnimationFrameAsset(status: RecordingStatus, animationPhase: Int, in rect: CGRect) -> Bool {
        let frameName = BarnOwlAnimationFrames.imageName(for: animationPhase)
        guard let owl = NSImage(named: frameName) ?? NSImage(named: "BarnOwlLogo") else { return false }

        if status != .idle {
            status.haloColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.4, dy: 1.4)).fill()
        }

        let imageRect = rect.insetBy(dx: 0.6, dy: 0.6)
        owl.draw(
            in: imageRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )

        if status == .recording {
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: CGRect(x: rect.maxX - 6, y: rect.maxY - 7, width: 5, height: 5)).fill()
        }
        return true
    }

    private static func drawLogoAsset(status: RecordingStatus, pose: BarnOwlAnimationPose, in rect: CGRect) -> Bool {
        guard let logo = NSImage(named: "BarnOwlLogo") else { return false }
        let size = min(rect.width, rect.height)

        if status != .idle {
            status.haloColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.4, dy: 1.4)).fill()
        }

        let logoRect = rect.insetBy(dx: 0.9, dy: 0.9)
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(
            by: rect.midX + CGFloat(pose.turn) * size * 0.018,
            yBy: rect.midY + abs(CGFloat(pose.turn)) * size * 0.004
        )
        transform.rotate(byDegrees: pose.turn * 5.5)
        transform.translateX(by: -rect.midX, yBy: -rect.midY)
        transform.concat()
        logo.draw(in: logoRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])

        drawAnimatedEyes(size: size, rect: rect, pose: pose)

        if abs(pose.earLift) > 0.01 {
            drawEarTwitch(size: size, rect: rect, side: .left, lift: pose.earLift)
            drawEarTwitch(size: size, rect: rect, side: .right, lift: pose.earLift)
        }
        NSGraphicsContext.restoreGraphicsState()

        if status == .recording {
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: CGRect(x: rect.maxX - 6, y: rect.maxY - 7, width: 5, height: 5)).fill()
        }
        return true
    }

    private static func drawAnimatedEyes(size: CGFloat, rect: CGRect, pose: BarnOwlAnimationPose) {
        drawAnimatedEye(
            center: CGPoint(x: rect.minX + size * 0.39, y: rect.minY + size * 0.535),
            size: size,
            pupilOffset: pose.turn,
            blink: pose.blink
        )
        drawAnimatedEye(
            center: CGPoint(x: rect.minX + size * 0.61, y: rect.minY + size * 0.535),
            size: size,
            pupilOffset: pose.turn,
            blink: pose.blink
        )
    }

    private static func drawAnimatedEye(center: CGPoint, size: CGFloat, pupilOffset: Double, blink: Bool) {
        let eyeRect = CGRect(
            x: center.x - size * 0.123,
            y: center.y - size * 0.123,
            width: size * 0.246,
            height: size * 0.246
        )

        NSColor.barnOwlCream.setFill()
        NSBezierPath(ovalIn: eyeRect).fill()
        NSColor.barnOwlClay.withAlphaComponent(0.56).setStroke()
        let outline = NSBezierPath(ovalIn: eyeRect)
        outline.lineWidth = max(0.45, size * 0.018)
        outline.stroke()

        if blink {
            let lid = closedEyelidPath(in: eyeRect)
            NSColor.barnOwlAmberLight.withAlphaComponent(0.92).setFill()
            lid.fill()
            NSColor.barnOwlClay.withAlphaComponent(0.80).setStroke()
            lid.lineWidth = max(0.6, size * 0.022)
            lid.stroke()
            return
        }

        let pupilSize = size * 0.108
        let offset = CGFloat(pupilOffset) * size * 0.043
        let pupilRect = CGRect(
            x: center.x - pupilSize / 2 + offset,
            y: center.y - pupilSize / 2,
            width: pupilSize,
            height: pupilSize
        )
        NSColor(calibratedWhite: 0.025, alpha: 1).setFill()
        NSBezierPath(ovalIn: pupilRect).fill()

        NSColor.white.withAlphaComponent(0.92).setFill()
        NSBezierPath(
            ovalIn: CGRect(
                x: pupilRect.minX + pupilSize * 0.18,
                y: pupilRect.maxY - pupilSize * 0.38,
                width: pupilSize * 0.34,
                height: pupilSize * 0.34
            )
        ).fill()
    }

    private static func closedEyelidPath(in rect: CGRect) -> NSBezierPath {
        let width = rect.width
        let height = rect.height
        let path = NSBezierPath()
        path.move(to: CGPoint(x: rect.minX + width * 0.06, y: rect.midY + height * 0.03))
        path.curve(
            to: CGPoint(x: rect.maxX - width * 0.06, y: rect.midY + height * 0.03),
            controlPoint1: CGPoint(x: rect.minX + width * 0.26, y: rect.midY - height * 0.15),
            controlPoint2: CGPoint(x: rect.maxX - width * 0.26, y: rect.midY - height * 0.15)
        )
        path.curve(
            to: CGPoint(x: rect.minX + width * 0.06, y: rect.midY + height * 0.03),
            controlPoint1: CGPoint(x: rect.maxX - width * 0.24, y: rect.midY + height * 0.19),
            controlPoint2: CGPoint(x: rect.minX + width * 0.24, y: rect.midY + height * 0.19)
        )
        path.close()
        return path
    }

    private static func drawEarTwitch(size: CGFloat, rect: CGRect, side: StatusOwlEarSide, lift: Double) {
        let direction: CGFloat = side == .left ? -1 : 1
        let center = CGPoint(
            x: rect.midX + direction * size * 0.31,
            y: rect.midY + size * (0.34 + CGFloat(max(0, lift)) * 0.02)
        )
        let earRect = CGRect(
            x: center.x - size * 0.055,
            y: center.y - size * 0.055,
            width: size * 0.11,
            height: size * 0.12
        )

        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: center.x, yBy: center.y)
        transform.rotate(byDegrees: direction * (16 + CGFloat(lift) * 10))
        transform.translateX(by: -center.x, yBy: -center.y)
        transform.concat()

        let path = NSBezierPath()
        path.move(to: CGPoint(x: earRect.minX, y: earRect.minY))
        path.curve(
            to: CGPoint(x: earRect.midX, y: earRect.maxY),
            controlPoint1: CGPoint(x: earRect.minX, y: earRect.midY),
            controlPoint2: CGPoint(x: earRect.midX - direction * size * 0.025, y: earRect.maxY)
        )
        path.curve(
            to: CGPoint(x: earRect.maxX, y: earRect.minY + earRect.height * 0.12),
            controlPoint1: CGPoint(x: earRect.midX + direction * size * 0.035, y: earRect.maxY),
            controlPoint2: CGPoint(x: earRect.maxX, y: earRect.midY)
        )
        path.close()
        NSColor.barnOwlAmberLight.withAlphaComponent(0.64).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawEye(center: CGPoint, size: CGFloat, pupilOffset: Double, blink: Bool) {
        let eyeRect = CGRect(
            x: center.x - size * 0.09,
            y: center.y - size * 0.09,
            width: size * 0.18,
            height: size * 0.18
        )

        if blink {
            NSColor.barnOwlCream.setFill()
            NSBezierPath(ovalIn: eyeRect).fill()
            let lid = closedEyelidPath(in: eyeRect)
            NSColor.barnOwlAmberLight.withAlphaComponent(0.92).setFill()
            lid.fill()
            NSColor.barnOwlClay.withAlphaComponent(0.80).setStroke()
            lid.lineWidth = max(0.6, size * 0.020)
            lid.stroke()
        } else {
            NSColor.white.setFill()
            NSBezierPath(ovalIn: eyeRect).fill()
            let offset = CGFloat(pupilOffset) * size * 0.015
            NSColor(calibratedWhite: 0.04, alpha: 1).setFill()
            NSBezierPath(ovalIn: eyeRect.insetBy(dx: size * 0.055, dy: size * 0.055).offsetBy(dx: offset, dy: 0)).fill()
        }
    }

    private static func drawBeak(size: CGFloat, rect: CGRect) {
        let beak = NSBezierPath()
        beak.move(to: CGPoint(x: rect.midX, y: rect.minY + size * 0.36))
        beak.line(to: CGPoint(x: rect.midX - size * 0.055, y: rect.minY + size * 0.46))
        beak.line(to: CGPoint(x: rect.midX + size * 0.055, y: rect.minY + size * 0.46))
        beak.close()
        NSColor.barnOwlAmberLight.setFill()
        beak.fill()
    }

    private static func drawFacePatches(size: CGFloat, rect: CGRect) {
        NSColor.barnOwlCream.setFill()
        facePatchPath(size: size, rect: rect, mirrored: false).fill()
        facePatchPath(size: size, rect: rect, mirrored: true).fill()
    }

    private static func facePatchPath(size: CGFloat, rect: CGRect, mirrored: Bool) -> NSBezierPath {
        let minX = rect.minX
        let maxX = rect.maxX
        let minY = rect.minY
        func x(_ value: CGFloat) -> CGFloat {
            mirrored ? maxX - size * value : minX + size * value
        }

        let path = NSBezierPath()
        path.move(to: CGPoint(x: x(0.50), y: minY + size * 0.68))
        path.curve(
            to: CGPoint(x: x(0.29), y: minY + size * 0.56),
            controlPoint1: CGPoint(x: x(0.45), y: minY + size * 0.75),
            controlPoint2: CGPoint(x: x(0.33), y: minY + size * 0.72)
        )
        path.curve(
            to: CGPoint(x: x(0.36), y: minY + size * 0.31),
            controlPoint1: CGPoint(x: x(0.22), y: minY + size * 0.42),
            controlPoint2: CGPoint(x: x(0.25), y: minY + size * 0.31)
        )
        path.curve(
            to: CGPoint(x: x(0.50), y: minY + size * 0.34),
            controlPoint1: CGPoint(x: x(0.42), y: minY + size * 0.28),
            controlPoint2: CGPoint(x: x(0.48), y: minY + size * 0.30)
        )
        path.curve(
            to: CGPoint(x: x(0.50), y: minY + size * 0.68),
            controlPoint1: CGPoint(x: x(0.58), y: minY + size * 0.46),
            controlPoint2: CGPoint(x: x(0.57), y: minY + size * 0.60)
        )
        path.close()
        return path
    }

    private static func drawWing(size: CGFloat, rect: CGRect) {
        let wing = NSBezierPath()
        wing.move(to: CGPoint(x: rect.minX + size * 0.34, y: rect.minY + size * 0.34))
        wing.curve(
            to: CGPoint(x: rect.minX + size * 0.66, y: rect.minY + size * 0.34),
            controlPoint1: CGPoint(x: rect.minX + size * 0.42, y: rect.minY + size * 0.24),
            controlPoint2: CGPoint(x: rect.minX + size * 0.58, y: rect.minY + size * 0.24)
        )
        NSColor(calibratedWhite: 1, alpha: 0.20).setStroke()
        wing.lineWidth = 0.8
        wing.stroke()
    }

    private static func owlHeadPath(in rect: CGRect) -> NSBezierPath {
        let minX = rect.minX
        let maxX = rect.maxX
        let minY = rect.minY
        let width = rect.width
        let height = rect.height

        let path = NSBezierPath()
        path.move(to: CGPoint(x: minX + width * 0.16, y: minY + height * 0.64))
        path.line(to: CGPoint(x: minX + width * 0.22, y: minY + height * 0.92))
        path.line(to: CGPoint(x: minX + width * 0.39, y: minY + height * 0.76))
        path.curve(
            to: CGPoint(x: minX + width * 0.61, y: minY + height * 0.76),
            controlPoint1: CGPoint(x: minX + width * 0.46, y: minY + height * 0.82),
            controlPoint2: CGPoint(x: minX + width * 0.54, y: minY + height * 0.82)
        )
        path.line(to: CGPoint(x: minX + width * 0.78, y: minY + height * 0.92))
        path.line(to: CGPoint(x: minX + width * 0.84, y: minY + height * 0.64))
        path.curve(
            to: CGPoint(x: minX + width * 0.5, y: minY + height * 0.05),
            controlPoint1: CGPoint(x: maxX, y: minY + height * 0.42),
            controlPoint2: CGPoint(x: minX + width * 0.82, y: minY + height * 0.05)
        )
        path.curve(
            to: CGPoint(x: minX + width * 0.16, y: minY + height * 0.64),
            controlPoint1: CGPoint(x: minX + width * 0.18, y: minY + height * 0.05),
            controlPoint2: CGPoint(x: minX, y: minY + height * 0.42)
        )
        path.close()
        return path
    }
}

private extension RecordingStatus {
    static var fixedStatusItemLength: CGFloat { 28 }

    var owlFill: NSColor {
        switch self {
        case .recording:
            NSColor(calibratedRed: 0.47, green: 0.28, blue: 0.15, alpha: 1)
        case .processing:
            NSColor.barnOwlMoss
        case .failed:
            NSColor.barnOwlAmber
        case .idle, .preparing:
            NSColor(calibratedRed: 0.54, green: 0.36, blue: 0.21, alpha: 1)
        }
    }

    var haloColor: NSColor {
        switch self {
        case .recording:
            NSColor.systemRed.withAlphaComponent(0.2)
        case .processing:
            NSColor.barnOwlMoss.withAlphaComponent(0.24)
        case .failed:
            NSColor.barnOwlAmber.withAlphaComponent(0.24)
        case .preparing:
            NSColor.barnOwlAmberLight.withAlphaComponent(0.22)
        case .idle:
            NSColor.clear
        }
    }

    var blinkCadence: Int {
        switch self {
        case .recording, .processing, .idle, .failed:
            4
        case .preparing:
            7
        }
    }
}

private extension NSColor {
    static let barnOwlAmber = NSColor(calibratedRed: 0.78, green: 0.46, blue: 0.18, alpha: 1)
    static let barnOwlAmberLight = NSColor(calibratedRed: 0.96, green: 0.68, blue: 0.34, alpha: 1)
    static let barnOwlClay = NSColor(calibratedRed: 0.45, green: 0.26, blue: 0.13, alpha: 1)
    static let barnOwlCream = NSColor(calibratedRed: 0.97, green: 0.91, blue: 0.80, alpha: 1)
    static let barnOwlMoss = NSColor(calibratedRed: 0.36, green: 0.43, blue: 0.36, alpha: 1)
}
