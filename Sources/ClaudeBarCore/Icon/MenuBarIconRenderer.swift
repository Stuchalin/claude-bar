// Adapted from CodexBar (https://github.com/steipete/CodexBar), Sources/CodexBar/IconRenderer.swift
// at commit a91669f. Copyright (c) 2026 Peter Steinberger. MIT License; see THIRD_PARTY_NOTICES.md.
// Kept: the 18 pt height, the two-bar pixel grid (30 px wide at x 3, top y 19 h 12, bottom y 5 h 8
// at 2×), track/stroke/fill alphas with stale dimming, the inset 1 pt outline and the rounded fill
// width. Dropped: provider decorations, credits layouts, animation, caching and status overlays.
// Added: the 24 pt wide canvas, per-scale pixel snapping, the dashed unknown bar and the Claude
// starburst to the right of the bars (ClaudeBar's own drawing, not a copied asset).

import CoreGraphics
import Foundation

/// Draws the menu bar icon into a bitmap with CoreGraphics only, so the exact pixels are testable
/// without AppKit. Only alpha carries meaning: the app wraps the result in a template image.
public enum MenuBarIconRenderer {
    /// Icon width in points: CodexBar's 18 pt bar column plus the starburst column.
    public static let widthPoints = 24
    /// Icon height in points.
    public static let heightPoints = 18
    /// Starburst opacity (owner-approved variant E).
    public static let starburstAlpha: CGFloat = 0.7
    /// Clear margin the starburst keeps around each bar, in device pixels.
    public static let barMarginPixels = 1

    /// Bar rectangles and starburst geometry in device pixels (origin bottom-left) at one scale.
    public struct Geometry: Equatable, Sendable {
        public struct Starburst: Equatable, Sendable {
            public let center: CGPoint
            public let longRay: CGFloat
            public let shortRay: CGFloat
            public let longHalfWidth: CGFloat
            public let shortHalfWidth: CGFloat
            public let coreRadius: CGFloat
        }

        public let scale: Int
        public let canvasWidth: Int
        public let canvasHeight: Int
        public let topBar: CGRect
        public let bottomBar: CGRect
        public let starburst: Starburst

        /// The grid is defined at 2×; other scales snap each edge to whole pixels.
        public init(scale: Int) {
            precondition(scale >= 1, "scale must be at least 1")
            self.scale = scale
            canvasWidth = MenuBarIconRenderer.widthPoints * scale
            canvasHeight = MenuBarIconRenderer.heightPoints * scale
            func px(_ gridValue: Int) -> CGFloat {
                (CGFloat(gridValue * scale) / 2).rounded()
            }
            func rect(x: Int, y: Int, w: Int, h: Int) -> CGRect {
                CGRect(x: px(x), y: px(y), width: px(w), height: px(h))
            }
            topBar = rect(x: 3, y: 19, w: 30, h: 12)
            bottomBar = rect(x: 3, y: 5, w: 30, h: 8)

            if scale == 1 {
                // At 1× the 2× star (centre x 20.5, reach 3.5 px) would touch the bar margin at
                // x 18; snap the centre to x 21 and shorten the long rays to the 3 px that fit.
                // Rays keep a 0.5 px minimum half-width so the star does not dissolve into gray.
                starburst = Starburst(
                    center: CGPoint(x: 21, y: 9),
                    longRay: 3,
                    shortRay: 2.1,
                    longHalfWidth: 0.6,
                    shortHalfWidth: 0.5,
                    coreRadius: 1
                )
            } else {
                let unit = CGFloat(scale) / 2
                starburst = Starburst(
                    center: CGPoint(x: px(41), y: px(18)),
                    longRay: 7 * unit,
                    shortRay: 4.8 * unit,
                    longHalfWidth: 1.1 * unit,
                    shortHalfWidth: 0.9 * unit,
                    coreRadius: 1.6 * unit
                )
            }
        }

        /// The bars grown by the clear margin: no starburst pixel may fall inside them.
        public var barZones: [CGRect] {
            let margin = CGFloat(MenuBarIconRenderer.barMarginPixels)
            return [topBar, bottomBar].map { $0.insetBy(dx: -margin, dy: -margin) }
        }

        /// The right-hand column the starburst lives in: everything right of the bar zones.
        public var starburstRegion: CGRect {
            let minX = barZones.map(\.maxX).max() ?? 0
            return CGRect(x: minX, y: 0, width: CGFloat(canvasWidth) - minX, height: CGFloat(canvasHeight))
        }
    }

    public enum Layers: Sendable {
        case full
        /// The starburst alone, without bars: lets tests inspect where it draws.
        case starburstOnly
    }

    public static func render(_ model: MenuBarIconModel, scale: Int, layers: Layers = .full) -> MenuBarIconRaster? {
        let geometry = Geometry(scale: scale)
        let width = geometry.canvasWidth
        let height = geometry.canvasHeight
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setShouldAntialias(true)
        context.interpolationQuality = .none

        drawStarburst(geometry.starburst, in: context)
        if layers == .full {
            drawBar(model.session, rect: geometry.topBar, scale: scale, in: context)
            drawBar(model.weekly, rect: geometry.bottomBar, scale: scale, in: context)
        }

        guard let image = context.makeImage(), let data = context.data else { return nil }
        let bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
        return MenuBarIconRaster(scale: scale, width: width, height: height, rgba: bytes, image: image)
    }

    /// Remaining share as a fill width in whole pixels (CodexBar's `fillWidthPixels`).
    static func fillWidthPixels(remaining: Double, rectWidth: Int) -> Int {
        let clamped = max(0, min(remaining / 100, 1))
        return max(0, min(rectWidth, Int((CGFloat(rectWidth) * CGFloat(clamped)).rounded())))
    }

    // MARK: - Starburst

    /// A simplified twelve-ray starburst: alternating long and short tapered rays around a small
    /// core, drawn opaque in a transparency layer so overlaps do not stack, then faded as a whole.
    private static func drawStarburst(_ star: Geometry.Starburst, in context: CGContext) {
        let center = star.center
        let rayCount = 12

        context.saveGState()
        context.setAlpha(starburstAlpha)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setFillColor(gray: 0, alpha: 1)
        for index in 0 ..< rayCount {
            let isLong = index.isMultiple(of: 2)
            let length = isLong ? star.longRay : star.shortRay
            let halfWidth = isLong ? star.longHalfWidth : star.shortHalfWidth
            // Offset by half a step so no ray points straight at the bars.
            let angle = (CGFloat(index) + 0.5) * (2 * .pi / CGFloat(rayCount))
            let direction = CGPoint(x: cos(angle), y: sin(angle))
            let normal = CGPoint(x: -direction.y, y: direction.x)
            context.move(to: CGPoint(x: center.x + normal.x * halfWidth, y: center.y + normal.y * halfWidth))
            context.addLine(to: CGPoint(x: center.x + direction.x * length, y: center.y + direction.y * length))
            context.addLine(to: CGPoint(x: center.x - normal.x * halfWidth, y: center.y - normal.y * halfWidth))
            context.closePath()
            context.fillPath()
        }
        let core = star.coreRadius
        context.fillEllipse(in: CGRect(x: center.x - core, y: center.y - core, width: core * 2, height: core * 2))
        context.endTransparencyLayer()
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
