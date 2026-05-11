import AppKit
import Foundation

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "")
guard !outputDirectory.path.isEmpty else {
    fatalError("Usage: swift scripts/generate_app_icon.swift <output-directory>")
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let sizes = [16, 32, 64, 128, 256, 512, 1024]
for size in sizes {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    drawBarnOwlIcon(size: CGFloat(size))
    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:])
    else {
        fatalError("Could not render \(size)x\(size) icon")
    }

    let url = outputDirectory.appendingPathComponent("barn-owl-\(size).png")
    try png.write(to: url, options: .atomic)
}

private func drawBarnOwlIcon(size: CGFloat) {
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    rect.fill()

    let background = NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22)
    NSColor(calibratedRed: 0.98, green: 0.93, blue: 0.83, alpha: 1).setFill()
    background.fill()

    let halo = NSBezierPath(ovalIn: rect.insetBy(dx: size * 0.13, dy: size * 0.13))
    NSColor(calibratedRed: 0.86, green: 0.60, blue: 0.28, alpha: 0.22).setFill()
    halo.fill()

    let head = owlHeadPath(in: rect.insetBy(dx: size * 0.16, dy: size * 0.12))
    NSColor(calibratedRed: 0.49, green: 0.31, blue: 0.17, alpha: 1).setFill()
    head.fill()
    NSColor(calibratedWhite: 0.08, alpha: 0.18).setStroke()
    head.lineWidth = max(1, size * 0.025)
    head.stroke()

    drawEye(center: CGPoint(x: size * 0.39, y: size * 0.53), size: size)
    drawEye(center: CGPoint(x: size * 0.61, y: size * 0.53), size: size)

    let beak = NSBezierPath()
    beak.move(to: CGPoint(x: size * 0.50, y: size * 0.39))
    beak.line(to: CGPoint(x: size * 0.44, y: size * 0.49))
    beak.line(to: CGPoint(x: size * 0.56, y: size * 0.49))
    beak.close()
    NSColor(calibratedRed: 0.96, green: 0.60, blue: 0.18, alpha: 1).setFill()
    beak.fill()

    let wing = NSBezierPath()
    wing.move(to: CGPoint(x: size * 0.32, y: size * 0.33))
    wing.curve(
        to: CGPoint(x: size * 0.68, y: size * 0.33),
        controlPoint1: CGPoint(x: size * 0.41, y: size * 0.23),
        controlPoint2: CGPoint(x: size * 0.59, y: size * 0.23)
    )
    NSColor(calibratedWhite: 0.08, alpha: 0.25).setStroke()
    wing.lineWidth = max(1, size * 0.026)
    wing.stroke()
}

private func drawEye(center: CGPoint, size: CGFloat) {
    let eyeRect = CGRect(
        x: center.x - size * 0.095,
        y: center.y - size * 0.095,
        width: size * 0.19,
        height: size * 0.19
    )
    let eye = NSBezierPath(ovalIn: eyeRect)
    NSColor.white.setFill()
    eye.fill()

    let pupilRect = eyeRect.insetBy(dx: size * 0.06, dy: size * 0.06)
    let pupil = NSBezierPath(ovalIn: pupilRect)
    NSColor(calibratedWhite: 0.05, alpha: 1).setFill()
    pupil.fill()
}

private func owlHeadPath(in rect: CGRect) -> NSBezierPath {
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
