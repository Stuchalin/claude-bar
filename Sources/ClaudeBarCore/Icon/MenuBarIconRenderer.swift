// Adapted from CodexBar (https://github.com/steipete/CodexBar), Sources/CodexBar/IconRenderer.swift
// at commit a91669f. Copyright (c) 2026 Peter Steinberger. MIT License; see THIRD_PARTY_NOTICES.md.
// Kept: the 18×18 pt canvas, the two-bar pixel grid (30 px wide, top y 19 h 12, bottom y 5 h 8 at
// 2×), track/stroke/fill alphas with stale dimming, the inset 1 pt outline and the rounded fill
// width. Dropped: provider decorations, credits layouts, animation, caching and status overlays.
// Added: per-scale pixel snapping, the dashed unknown bar and the Claude starburst watermark with
// its knockout (ClaudeBar's own drawing, not a copied asset).

import CoreGraphics
import Foundation

/// Draws the menu bar icon into a bitmap with CoreGraphics only, so the exact pixels are testable
/// without AppKit. Only alpha carries meaning: the app wraps the result in a template image.
public enum MenuBarIconRenderer {
    /// Icon size in points.
    public static let sizePoints = 18
    /// Watermark opacity, a starting value tuned at owner review.
    public static let watermarkAlpha: CGFloat = 0.3
    /// Clear gap around each bar, in device pixels, a starting value tuned at owner review.
    public static let knockoutGapPixels = 1

    /// Bar and knockout rectangles in device pixels (origin bottom-left) at one scale.
    public struct Geometry: Equatable, Sendable {
        public let scale: Int
        public let canvasPixels: Int
        public let topBar: CGRect
        public let bottomBar: CGRect

        /// CodexBar's grid is defined at 2×; other scales snap each edge to whole pixels.
        public init(scale: Int) {
            precondition(scale >= 1, "scale must be at least 1")
            self.scale = scale
            canvasPixels = MenuBarIconRenderer.sizePoints * scale
            func px(_ gridValue: Int) -> CGFloat {
                (CGFloat(gridValue * scale) / 2).rounded()
            }
            func rect(x: Int, y: Int, w: Int, h: Int) -> CGRect {
                CGRect(x: px(x), y: px(y), width: px(w), height: px(h))
            }
            let barWidth = 30
            let barX = (36 - barWidth) / 2
            topBar = rect(x: barX, y: 19, w: barWidth, h: 12)
            bottomBar = rect(x: barX, y: 5, w: barWidth, h: 8)
        }

        /// The zones around the bars where no watermark pixel may remain.
        public var knockoutZones: [CGRect] {
            let gap = CGFloat(MenuBarIconRenderer.knockoutGapPixels)
            return [topBar, bottomBar].map { $0.insetBy(dx: -gap, dy: -gap) }
        }

        /// The watermark's center: horizontally centered, vertically between the bars.
        var watermarkCenter: CGPoint {
            CGPoint(x: CGFloat(canvasPixels) / 2, y: (bottomBar.maxY + topBar.minY) / 2)
        }
    }

    public enum Layers: Sendable {
        case full
        /// The watermark after its knockout, without bars: lets tests inspect the knockout.
        case watermarkOnly
    }

    public static func render(_ model: MenuBarIconModel, scale: Int, layers: Layers = .full) -> MenuBarIconRaster? {
        let geometry = Geometry(scale: scale)
        let side = geometry.canvasPixels
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: side, height: side))
        context.setShouldAntialias(true)
        context.interpolationQuality = .none

        drawWatermark(in: context, geometry: geometry)
        if layers == .full {
            drawBar(model.session, rect: geometry.topBar, scale: scale, in: context)
            drawBar(model.weekly, rect: geometry.bottomBar, scale: scale, in: context)
        }

        guard let image = context.makeImage(), let data = context.data else { return nil }
        let bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: side * side * 4))
        return MenuBarIconRaster(scale: scale, width: side, height: side, rgba: bytes, image: image)
    }

    /// Remaining share as a fill width in whole pixels (CodexBar's `fillWidthPixels`).
    static func fillWidthPixels(remaining: Double, rectWidth: Int) -> Int {
        let clamped = max(0, min(remaining / 100, 1))
        return max(0, min(rectWidth, Int((CGFloat(rectWidth) * CGFloat(clamped)).rounded())))
    }

    // MARK: - Watermark

    /// A simplified twelve-ray starburst: alternating long and short tapered rays around a small
    /// core, drawn opaque in a transparency layer so overlaps do not stack, then faded as a whole.
    private static func drawWatermark(in context: CGContext, geometry: Geometry) {
        let pt = CGFloat(geometry.scale)
        let center = geometry.watermarkCenter
        let rayCount = 12

        context.saveGState()
        context.setAlpha(watermarkAlpha)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setFillColor(gray: 0, alpha: 1)
        for index in 0 ..< rayCount {
            let isLong = index.isMultiple(of: 2)
            let length = (isLong ? 9.5 : 6.5) * pt
            let halfWidth = (isLong ? 1.0 : 0.8) * pt
            // Offset by half a step so no ray runs along the gap between the bars like a third bar.
            let angle = (CGFloat(index) + 0.5) * (2 * .pi / CGFloat(rayCount))
            let direction = CGPoint(x: cos(angle), y: sin(angle))
            let normal = CGPoint(x: -direction.y, y: direction.x)
            context.move(to: CGPoint(x: center.x + normal.x * halfWidth, y: center.y + normal.y * halfWidth))
            context.addLine(to: CGPoint(x: center.x + direction.x * length, y: center.y + direction.y * length))
            context.addLine(to: CGPoint(x: center.x - normal.x * halfWidth, y: center.y - normal.y * halfWidth))
            context.closePath()
            context.fillPath()
        }
        let core = 1.6 * pt
        context.fillEllipse(in: CGRect(x: center.x - core, y: center.y - core, width: core * 2, height: core * 2))
        context.endTransparencyLayer()
        context.restoreGState()

        // Knockout: whole-pixel rectangles cleared without antialiasing leave exact zeros.
        context.saveGState()
        context.setShouldAntialias(false)
        context.setBlendMode(.clear)
        context.fill(geometry.knockoutZones)
        context.restoreGState()
    }

    // MARK: - Bars

    private static func drawBar(_ bar: MenuBarIconModel.Bar, rect: CGRect, scale: Int, in context: CGContext) {
        let strokeWidth = CGFloat(scale) // 1 pt
        let radius = rect.height / 2
        let trackPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let inset = strokeWidth / 2
        let strokeRect = rect.insetBy(dx: inset, dy: inset)
        let strokeRadius = max(0, radius - inset)
        let strokePath = CGPath(
            roundedRect: strokeRect,
            cornerWidth: strokeRadius,
            cornerHeight: strokeRadius,
            transform: nil
        )

        context.saveGState()
        defer { context.restoreGState() }
        context.setLineWidth(strokeWidth)

        switch bar {
        case .unknown:
            // Hollow, dashed outline: unlike 0 % it has no track fill, unlike stale it is broken.
            context.setStrokeColor(gray: 0, alpha: 0.44)
            context.setLineDash(phase: 0, lengths: [2 * CGFloat(scale), 2 * CGFloat(scale)])
            context.addPath(strokePath)
            context.strokePath()

        case let .remaining(remaining, stale):
            context.setFillColor(gray: 0, alpha: stale ? 0.18 : 0.28)
            context.addPath(trackPath)
            context.fillPath()
            context.setStrokeColor(gray: 0, alpha: stale ? 0.28 : 0.44)
            context.addPath(strokePath)
            context.strokePath()

            let fillWidth = fillWidthPixels(remaining: remaining, rectWidth: Int(rect.width))
            guard fillWidth > 0 else { return }
            context.addPath(trackPath)
            context.clip()
            context.setFillColor(gray: 0, alpha: stale ? 0.55 : 1.0)
            context.fill(CGRect(x: rect.minX, y: rect.minY, width: CGFloat(fillWidth), height: rect.height))
        }
    }
}

/// A rendered icon bitmap: the image for the status item and its premultiplied RGBA bytes.
public struct MenuBarIconRaster {
    public let scale: Int
    public let width: Int
    public let height: Int
    /// Premultiplied RGBA, top row first (CoreGraphics bitmap order).
    public let rgba: [UInt8]
    public let image: CGImage

    /// Alpha at a device pixel, `y` counted from the bottom like the drawing coordinates.
    public func alpha(x: Int, y: Int) -> UInt8 {
        precondition((0 ..< width).contains(x) && (0 ..< height).contains(y), "pixel out of bounds")
        return rgba[((height - 1 - y) * width + x) * 4 + 3]
    }
}
