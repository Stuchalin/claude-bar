import AppKit
import CoreGraphics

// Original vector drawing. Reference composition: CodexBar app icon.
// Twelve rounded rays; app-scale geometry, independent of the menu-bar glyph.
// Regenerate: Assets/AppIcon/build.sh (macOS, Xcode command line tools).
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let small = CommandLine.arguments.contains("--small")
let size = 2048
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
    bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: 2, y: 2)
ctx.translateBy(x: 0, y: 1024)
ctx.scaleBy(x: 1, y: -1)
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
}
func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
}
func fill(_ path: CGPath, _ c: CGColor) {
    ctx.addPath(path); ctx.setFillColor(c); ctx.fillPath()
}
// The visible body occupies exactly 824 px, centred on the 1024 px canvas.
ctx.translateBy(x: 100, y: 100)
ctx.scaleBy(x: 824 / 1024, y: 824 / 1024)
let shell = rounded(0, 0, 1024, 1024, 278)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 22,
    color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.24))
fill(shell, color(3,4,4))
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(shell); ctx.clip()
let rim = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(144,145,141), color(26,27,26), color(3,4,4), color(55,57,55)] as CFArray, locations: [0, 0.075, 0.85, 1])!
ctx.drawLinearGradient(rim, start: CGPoint(x: 120, y: 0), end: CGPoint(x: 900, y: 1024), options: [])
ctx.restoreGState()
fill(rounded(17, 17, 990, 990, 266), color(3,4,4))
ctx.addPath(rounded(94, 82, 836, 844, 194))
ctx.setStrokeColor(color(113,115,111)); ctx.setLineWidth(5); ctx.strokePath()

// Optical centre above the usage bar, with generous clearance on all sides.
let center = CGPoint(x: 512, y: 400)
ctx.setFillColor(color(204,124,94))
ctx.setStrokeColor(color(204,124,94))
ctx.setLineCap(.round)
ctx.setLineWidth(small ? 40 : 43)
let rayCount = small ? 8 : 12
for i in 0..<rayCount {
    let long = i.isMultiple(of: 2)
    let length: CGFloat = long ? 210 : (small ? 155 : 190)
    let angle = CGFloat(i) * 2 * .pi / CGFloat(rayCount)
    let dx = cos(angle), dy = sin(angle)
    ctx.move(to: center)
    ctx.addLine(to: CGPoint(x: center.x + dx * length, y: center.y + dy * length))
    ctx.strokePath()
}
let core: CGFloat = 64
ctx.fillEllipse(in: CGRect(x: center.x - core, y: center.y - core, width: core * 2, height: core * 2))

let track = rounded(212, 710, 600, 70, 35)
fill(track, color(38,40,39))
ctx.saveGState()
ctx.addPath(track); ctx.clip()
fill(rounded(212, 710, 450, 70, 5), color(139,202,189))
ctx.restoreGState()
fill(rounded(671, 710, 26, 70, 5), color(232,137,145))
let bitmap = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
