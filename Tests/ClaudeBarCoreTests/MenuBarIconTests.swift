@testable import ClaudeBarCore
import CoreGraphics
import Foundation
import Testing

@Suite("Menu bar icon")
struct MenuBarIconTests {
    typealias Bar = MenuBarIconModel.Bar

    /// The variants the plan pins, each drawn on both bars.
    enum Variant: String, CaseIterable, CustomTestStringConvertible {
        case empty, half, full, unknown, staleEmpty, staleHalf, staleFull

        var bar: Bar {
            switch self {
            case .empty: .remaining(0, stale: false)
            case .half: .remaining(50, stale: false)
            case .full: .remaining(100, stale: false)
            case .unknown: .unknown
            case .staleEmpty: .remaining(0, stale: true)
            case .staleHalf: .remaining(50, stale: true)
            case .staleFull: .remaining(100, stale: true)
            }
        }

        var testDescription: String { rawValue }
    }

    private static let scales = [1, 2]

    private func render(_ variant: Variant, scale: Int, layers: MenuBarIconRenderer.Layers = .full) throws
        -> MenuBarIconRaster
    {
        let model = MenuBarIconModel(session: variant.bar, weekly: variant.bar, accessibilityLabel: "")
        return try #require(MenuBarIconRenderer.render(model, scale: scale, layers: layers))
    }

    private func bars(_ scale: Int) -> [CGRect] {
        let geometry = MenuBarIconRenderer.Geometry(scale: scale)
        return [geometry.topBar, geometry.bottomBar]
    }

    /// Byte value of an alpha in 0…1, as CoreGraphics stores it.
    private func byte(_ alpha: Double) -> Int { Int((alpha * 255).rounded()) }

    private func expectAlpha(_ raster: MenuBarIconRaster, x: Int, y: Int, near alpha: Double,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        let actual = Int(raster.alpha(x: x, y: y))
        #expect(abs(actual - byte(alpha)) <= 2, "alpha at (\(x), \(y)) is \(actual), expected ≈ \(byte(alpha))",
                sourceLocation: sourceLocation)
    }

    // MARK: Geometry

    @Test("canvas is 24×18 pt; 2× bars are CodexBar's grid; 1× snaps every edge to whole pixels")
    func geometry() {
        let double = MenuBarIconRenderer.Geometry(scale: 2)
        #expect(double.canvasWidth == 48 && double.canvasHeight == 36)
        #expect(double.topBar == CGRect(x: 3, y: 19, width: 30, height: 12))
        #expect(double.bottomBar == CGRect(x: 3, y: 5, width: 30, height: 8))
        #expect(double.starburst.center == CGPoint(x: 41, y: 18))
        #expect(double.starburstRegion == CGRect(x: 34, y: 0, width: 14, height: 36))

        let single = MenuBarIconRenderer.Geometry(scale: 1)
        #expect(single.canvasWidth == 24 && single.canvasHeight == 18)
        #expect(single.topBar == CGRect(x: 2, y: 10, width: 15, height: 6))
        #expect(single.bottomBar == CGRect(x: 2, y: 3, width: 15, height: 4))
        #expect(single.barZones == [CGRect(x: 1, y: 9, width: 17, height: 8), CGRect(x: 1, y: 2, width: 17, height: 6)])
        #expect(single.starburstRegion == CGRect(x: 18, y: 0, width: 6, height: 18))
    }

    @Test("fill width rounds the remaining share and clamps it")
    func fillWidth() {
        #expect(MenuBarIconRenderer.fillWidthPixels(remaining: 0, rectWidth: 30) == 0)
        #expect(MenuBarIconRenderer.fillWidthPixels(remaining: 50, rectWidth: 30) == 15)
        #expect(MenuBarIconRenderer.fillWidthPixels(remaining: 100, rectWidth: 30) == 30)
        #expect(MenuBarIconRenderer.fillWidthPixels(remaining: 130, rectWidth: 30) == 30)
        #expect(MenuBarIconRenderer.fillWidthPixels(remaining: -5, rectWidth: 30) == 0)
        #expect(MenuBarIconRenderer.fillWidthPixels(remaining: 50, rectWidth: 15) == 8)
    }

    // MARK: Starburst

    @Test("the starburst draws only in its right-hand region, never inside the bars or their margin",
          arguments: Variant.allCases, scales)
    func starburstPlacement(variant: Variant, scale: Int) throws {
        let star = try render(variant, scale: scale, layers: .starburstOnly)
        let geometry = MenuBarIconRenderer.Geometry(scale: scale)
        var visible = 0
        for y in 0 ..< star.height {
            for x in 0 ..< star.width {
                let center = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                let alpha = star.alpha(x: x, y: y)
                if geometry.starburstRegion.contains(center) {
                    #expect(!geometry.barZones.contains { $0.contains(center) })
                    if alpha > 0 {
                        visible += 1
                        #expect(Int(alpha) <= byte(MenuBarIconRenderer.starburstAlpha) + 1, "starburst is translucent")
                    }
                } else {
                    #expect(alpha == 0, "starburst pixel at (\(x), \(y)) outside its region")
                }
            }
        }
        #expect(visible >= 9 * scale * scale, "starburst too small to read")
        // The core is solid at the starburst opacity.
        let core = geometry.starburst.center
        expectAlpha(star, x: Int(core.x), y: Int(core.y), near: MenuBarIconRenderer.starburstAlpha)

        // In the full icon the starburst region is the starburst alone (no overlap, no knockout) and
        // nothing but the bars draws left of it.
        let full = try render(variant, scale: scale)
        for y in 0 ..< full.height {
            for x in 0 ..< full.width {
                let center = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                if geometry.starburstRegion.contains(center) {
                    #expect(full.alpha(x: x, y: y) == star.alpha(x: x, y: y))
                } else if !geometry.barZones.contains(where: { $0.contains(center) }) {
                    #expect(full.alpha(x: x, y: y) == 0, "stray pixel at (\(x), \(y))")
                }
            }
        }
    }

    // MARK: Bars

    @Test("0 % shows only the track; 100 % is filled; 50 % fills the left half", arguments: scales)
    func fillLevels(scale: Int) throws {
        let empty = try render(.empty, scale: scale)
        let half = try render(.half, scale: scale)
        let full = try render(.full, scale: scale)
        for bar in bars(scale) {
            let y = Int(bar.midY)
            let left = Int(bar.minX + bar.width / 4)
            let right = Int(bar.minX + bar.width * 3 / 4)
            expectAlpha(empty, x: left, y: y, near: 0.28)
            expectAlpha(empty, x: right, y: y, near: 0.28)
            expectAlpha(full, x: left, y: y, near: 1)
            expectAlpha(full, x: right, y: y, near: 1)
            expectAlpha(half, x: left, y: y, near: 1)
            expectAlpha(half, x: right, y: y, near: 0.28)

            // The progress edge is a straight cut at the rounded fill width.
            let edge = Int(bar.minX) + MenuBarIconRenderer.fillWidthPixels(remaining: 50, rectWidth: Int(bar.width))
            expectAlpha(half, x: edge - 1, y: y, near: 1)
            expectAlpha(half, x: edge, y: y, near: 0.28)
        }
    }

    @Test("stale values are dimmed versions of fresh ones", arguments: scales)
    func stale(scale: Int) throws {
        let staleEmpty = try render(.staleEmpty, scale: scale)
        let staleHalf = try render(.staleHalf, scale: scale)
        let staleFull = try render(.staleFull, scale: scale)
        for bar in bars(scale) {
            let y = Int(bar.midY)
            let left = Int(bar.minX + bar.width / 4)
            let right = Int(bar.minX + bar.width * 3 / 4)
            expectAlpha(staleEmpty, x: right, y: y, near: 0.18)
            // The 0.55 fill is drawn over the 0.18 track, as in CodexBar.
            let staleFill = 0.55 + 0.18 * (1 - 0.55)
            expectAlpha(staleFull, x: right, y: y, near: staleFill)
            expectAlpha(staleHalf, x: left, y: y, near: staleFill)
            expectAlpha(staleHalf, x: right, y: y, near: 0.18)
        }
    }

    @Test("unknown is a hollow, dashed outline", arguments: scales)
    func unknown(scale: Int) throws {
        let raster = try render(.unknown, scale: scale)
        for bar in bars(scale) {
            // No track fill: the middle row between the rounded ends is clear.
            let y = Int(bar.midY)
            for x in Int(bar.minX + bar.height / 2) ..< Int(bar.maxX - bar.height / 2) {
                #expect(raster.alpha(x: x, y: y) == 0, "unknown interior at (\(x), \(y)) is not clear")
            }
            // The top outline row along the straight part has both dashes and gaps.
            let top = Int(bar.maxY) - 1
            let straight = (Int(bar.minX + bar.height / 2)) ..< (Int(bar.maxX - bar.height / 2))
            let alphas = straight.map { raster.alpha(x: $0, y: top) }
            #expect(alphas.contains(0))
            #expect(alphas.contains { $0 > 0 })
        }
    }

    @Test("all variants render differently from each other", arguments: scales)
    func distinct(scale: Int) throws {
        let rasters = try Variant.allCases.map { ($0, try render($0, scale: scale).rgba) }
        for (index, (a, aBytes)) in rasters.enumerated() {
            for (b, bBytes) in rasters[(index + 1)...] {
                #expect(aBytes != bBytes, "\(a) and \(b) look the same")
            }
        }
    }

    @Test("rendering is deterministic", arguments: scales)
    func deterministic(scale: Int) throws {
        for variant in Variant.allCases {
            #expect(try render(variant, scale: scale).rgba == render(variant, scale: scale).rgba)
        }
    }

    @Test("session draws on top, weekly on the bottom", arguments: scales)
    func barPlacement(scale: Int) throws {
        let model = MenuBarIconModel(session: .remaining(100, stale: false), weekly: .remaining(0, stale: false),
                                     accessibilityLabel: "")
        let raster = try #require(MenuBarIconRenderer.render(model, scale: scale))
        let geometry = MenuBarIconRenderer.Geometry(scale: scale)
        expectAlpha(raster, x: Int(geometry.topBar.midX), y: Int(geometry.topBar.midY), near: 1)
        expectAlpha(raster, x: Int(geometry.bottomBar.midX), y: Int(geometry.bottomBar.midY), near: 0.28)
        #expect(raster.image.width == 24 * scale && raster.image.height == 18 * scale)
    }

    // MARK: Model and VoiceOver label

    private typealias F = RefreshFixtures

    @Test("model maps presentations to bars and states both percentages")
    func model() {
        var status = RefreshStatus()
        let unknown = MenuBarIconModel(status: status)
        #expect(unknown.session == .unknown && unknown.weekly == .unknown)
        #expect(unknown.accessibilityLabel == "Claude usage: Session unknown, Weekly unknown")

        status.session = MetricState(presentation: .fresh(.window(F.window(used: 12.4))), allowsForecast: true)
        status.weekly = MetricState(presentation: .fresh(.window(F.window(used: 1))), allowsForecast: true)
        let fresh = MenuBarIconModel(status: status)
        #expect(fresh.session == .remaining(87.6, stale: false))
        #expect(fresh.weekly == .remaining(99, stale: false))
        #expect(fresh.accessibilityLabel == "Claude usage: Session 88% left, Weekly 99% left")

        status.session = MetricState(presentation: .stale(.window(F.window(used: 130)), lastSeenAt: F.t0),
                                     allowsForecast: false)
        status.weekly = MetricState(presentation: .waitingForFreshData(lastSeenAt: F.t0), allowsForecast: false)
        let stale = MenuBarIconModel(status: status)
        #expect(stale.session == .remaining(0, stale: true))
        #expect(stale.weekly == .unknown)
        #expect(stale.accessibilityLabel == "Claude usage: Session 0% left (stale), Weekly waiting for fresh data")
    }
}
