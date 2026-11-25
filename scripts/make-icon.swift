// Zeichnet das Kelter-App-Icon (stilisierte Weinpresse) und schreibt ein AppIcon.appiconset.
// Aufruf: swift make-icon.swift <Zielordner .appiconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func drawIcon(in context: CGContext, size: CGFloat) {
    let s = size / 1024
    context.saveGState()
    context.scaleBy(x: s, y: s)
    // Koordinaten: Ursprung unten links (CoreGraphics), 1024er Raster.

    // Grundform mit macOS-typischem Rand
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    context.addPath(bodyPath)
    context.setFillColor(color(0x4A1230).cgColor)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(bodyPath)
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0x9B2C5A).cgColor, color(0x3A0D27).cgColor] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 300, y: 924), end: CGPoint(x: 724, y: 100), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // dezenter Glanz oben
    context.setFillColor(NSColor.white.withAlphaComponent(0.06).cgColor)
    context.fillEllipse(in: CGRect(x: -100, y: 560, width: 1224, height: 700))
    context.restoreGState()

    let white = NSColor.white.withAlphaComponent(0.95).cgColor
    let shade = color(0x3A0D27, 0.55).cgColor
    func rounded(_ rect: CGRect, _ radius: CGFloat, _ fill: CGColor) {
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(fill)
        context.fillPath()
    }

    // Weintropfen unten
    let drop = CGMutablePath()
    drop.move(to: CGPoint(x: 512, y: 300))
    drop.addCurve(to: CGPoint(x: 466, y: 212), control1: CGPoint(x: 500, y: 270), control2: CGPoint(x: 466, y: 248))
    drop.addArc(center: CGPoint(x: 512, y: 212), radius: 46, startAngle: .pi, endAngle: 0, clockwise: false)
    drop.addCurve(to: CGPoint(x: 512, y: 300), control1: CGPoint(x: 558, y: 248), control2: CGPoint(x: 524, y: 270))
    context.addPath(drop)
    context.setFillColor(color(0xF2A7C3).cgColor)
    context.fillPath()

    // Wanne / Sockel
    rounded(CGRect(x: 292, y: 318, width: 440, height: 46), 23, white)
    // Pfosten und Querbalken
    rounded(CGRect(x: 312, y: 364, width: 46, height: 420), 16, white)
    rounded(CGRect(x: 666, y: 364, width: 46, height: 420), 16, white)
    rounded(CGRect(x: 286, y: 760, width: 452, height: 60), 24, white)

    // Korb mit Dauben
    let basket = CGRect(x: 392, y: 364, width: 240, height: 200)
    rounded(basket, 18, white)
    context.setFillColor(shade)
    for index in 1...4 {
        let x = basket.minX + CGFloat(index) * basket.width / 5 - 5
        context.fill(CGRect(x: x, y: basket.minY + 16, width: 10, height: basket.height - 32))
    }
    // Pressplatte
    rounded(CGRect(x: 380, y: 564, width: 264, height: 34), 12, white)

    // Spindel mit Gewinde
    let screw = CGRect(x: 490, y: 598, width: 44, height: 162)
    rounded(screw, 10, white)
    context.setStrokeColor(shade)
    context.setLineWidth(9)
    context.setLineCap(.round)
    var y = screw.minY + 18
    while y < screw.maxY - 12 {
        context.move(to: CGPoint(x: screw.minX + 6, y: y))
        context.addLine(to: CGPoint(x: screw.maxX - 6, y: y + 14))
        y += 26
    }
    context.strokePath()

    // Drehgriff
    rounded(CGRect(x: 420, y: 662, width: 184, height: 22), 11, white)
    context.setFillColor(white)
    context.fillEllipse(in: CGRect(x: 400, y: 655, width: 36, height: 36))
    context.fillEllipse(in: CGRect(x: 588, y: 655, width: 36, height: 36))

    context.restoreGState()
}

let sizes: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []
for (points, scale) in sizes {
    let pixels = points * scale
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.cgContext.interpolationQuality = .high
    drawIcon(in: graphics.cgContext, size: CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try rep.representation(using: .png, properties: [:])!.write(to: output.appending(path: name))
    images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: output.appending(path: "Contents.json"))
print("Icon geschrieben nach \(output.path)")
