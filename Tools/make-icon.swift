// Draws the app icon and writes an .iconset, ready for `iconutil`.
//
// Run it with `make icon`. The output — Resources/AppIcon.icns — is
// committed, so a fresh checkout does not have to run this at all; the
// script is here to be the source of the art rather than a build step.
//
// CoreGraphics rather than a converter. The mark is two stroked
// rectangles and a line, and this project builds with the Command Line
// Tools alone — pulling in ImageMagick or librsvg to draw three shapes
// would cost more than it saves. Nothing here is imported by the app.
//
// ## The mark
//
// Copied from atrium's own `frontend/public/logo.svg` — "frame & void":
// an outer square (the building) around an inset open square (the
// courtyard), with a lintel crossing the upper third. The 16 and 32 pt
// sizes use `favicon.svg` instead, which is the same idea with the
// lintel dropped and thicker strokes, because at that size the inner
// stroke alone already reads as an opening in a wall. Both files carry
// that reasoning in their own comments; this follows it rather than
// scaling one mark down and hoping.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outputDirectory = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: "build/AppIcon.iconset")

/// Sizes an .icns wants, as (pixels, filename).
let wanted: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]

func draw(size pixels: Int) -> CGImage? {
    let side = CGFloat(pixels)
    guard
        let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    // Apple's macOS icon grid: the art sits on a rounded plate inset
    // from the full canvas, not edge to edge. 824/1024 with a corner
    // radius of 185/824 is the shape every system icon uses; matching it
    // is what stops this looking like a sticker next to Finder.
    let plateInset = side * (100.0 / 1024.0)
    let plate = CGRect(
        x: plateInset, y: plateInset,
        width: side - plateInset * 2, height: side - plateInset * 2)
    let radius = plate.width * (185.0 / 824.0)

    let platePath = CGPath(
        roundedRect: plate, cornerWidth: radius, cornerHeight: radius,
        transform: nil)
    context.addPath(platePath)
    context.clip()

    // Near-black, matching the recording panel. A flat fill rather than
    // a gradient: the mark is a thin monochrome stroke, and anything
    // busy behind it costs legibility at 16 pt for decoration nobody
    // sees at 512.
    context.setFillColor(CGColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1))
    context.fill(plate)

    // The mark, white, drawn in its own coordinate box and mapped onto
    // the plate. SVG's y axis points down and CoreGraphics' points up,
    // so the box is flipped — without which the lintel ends up crossing
    // the *lower* third and the mark is subtly upside down.
    let markBox = plate.insetBy(dx: plate.width * 0.19, dy: plate.width * 0.19)
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.setLineCap(.square)
    context.setLineJoin(.miter)

    // Below 33 pt: `favicon.svg` — no lintel, thicker strokes.
    let simplified = pixels <= 32
    let viewBox: CGFloat = simplified ? 32 : 64
    let scale = markBox.width / viewBox

    func place(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(
            x: markBox.minX + x * scale,
            // Flip: SVG's y is measured from the top of the box.
            y: markBox.minY + (viewBox - y - h) * scale,
            width: w * scale, height: h * scale)
    }

    if simplified {
        context.setLineWidth(3 * scale)
        let outer = place(3, 3, 26, 26)
        context.addPath(
            CGPath(
                roundedRect: outer, cornerWidth: 1 * scale, cornerHeight: 1 * scale,
                transform: nil))
        context.strokePath()

        context.setLineWidth(2 * scale)
        context.stroke(place(10, 10, 12, 12))
    } else {
        context.setLineWidth(4 * scale)
        let outer = place(6, 6, 52, 52)
        context.addPath(
            CGPath(
                roundedRect: outer, cornerWidth: 2 * scale, cornerHeight: 2 * scale,
                transform: nil))
        context.strokePath()

        context.setLineWidth(2.5 * scale)
        context.stroke(place(18, 18, 28, 28))

        // The lintel: a beam across the upper third of the void.
        let y = markBox.minY + (viewBox - 26) * scale
        context.move(to: CGPoint(x: markBox.minX + 18 * scale, y: y))
        context.addLine(to: CGPoint(x: markBox.minX + 46 * scale, y: y))
        context.strokePath()
    }

    return context.makeImage()
}

try? FileManager.default.createDirectory(
    at: outputDirectory, withIntermediateDirectories: true)

for (pixels, name) in wanted {
    guard let image = draw(size: pixels) else {
        FileHandle.standardError.write(Data("could not draw \(pixels)px\n".utf8))
        exit(1)
    }
    let url = outputDirectory.appending(path: name)
    guard
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else {
        FileHandle.standardError.write(Data("could not write \(name)\n".utf8))
        exit(1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    print("wrote \(name) (\(pixels)px)")
}
