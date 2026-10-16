// Adapted from CodexBar (https://github.com/steipete/CodexBar), Sources/CodexBar/UsageProgressBar.swift
// at commit a91669f. Copyright (c) 2026 Peter Steinberger. MIT License; see THIRD_PARTY_NOTICES.md.
// Kept: the single-Canvas track/fill and the striped pace tip. Dropped: warning and work-day
// markers and menu-highlight colors (ClaudeBar's card rows are never highlighted).

import AppKit
import SwiftUI

/// Capsule progress bar, 6 pt high, with an optional pace marker. No implicit animations.
struct UsageProgressBar: View {
    private static let paceStripeCount = 3
    private static let paceStripeWidth: CGFloat = 2
    private static let stripePunchOpacity = 0.9

    let percent: Double
    let tint: Color
    let accessibilityLabel: String
    var pacePercent: Double?
    /// `true` for a reserve (green marker), `false` for a deficit (red marker).
    var paceOnTop = true
    @Environment(\.displayScale) private var displayScale

    private var clamped: Double { min(100, max(0, percent)) }

    var body: some View {
        // One Canvas for track, fill and pace punch-out, as CodexBar: no compositing modifiers.
        Canvas { context, size in
            let scale = max(displayScale, 1)
            let fillWidth = size.width * Self.renderedFillPercent(clamped) / 100
            let paceWidth = size.width * Self.clampedPercent(pacePercent) / 100
            let tipWidth = max(25, size.height * 6.5)
            let stripeInset = 1 / scale
            let stripeSpan = Self.paceStripeWidth * CGFloat(Self.paceStripeCount)
            let tipOffset = paceWidth - tipWidth + stripeSpan / 2 + stripeInset
            let cornerSize = CGSize(width: size.height / 2, height: size.height / 2)
            let rect = CGRect(origin: .zero, size: size)

            context.clip(to: Path(rect))
            context.fill(
                Path { $0.addRoundedRect(in: rect, cornerSize: cornerSize) },
                with: .color(Color(nsColor: .tertiaryLabelColor).opacity(0.22))
            )
            if fillWidth > 0 {
                let fillRect = CGRect(x: 0, y: 0, width: min(fillWidth, size.width), height: size.height)
                context.fill(Path { $0.addRoundedRect(in: fillRect, cornerSize: cornerSize) }, with: .color(tint))
            }
            if pacePercent != nil {
                let stripes = Self.paceStripePaths(size: CGSize(width: tipWidth, height: size.height), scale: scale)
                let shift = CGAffineTransform(translationX: tipOffset, y: 0)
                context.blendMode = .destinationOut
                context.fill(stripes.punched.applying(shift), with: .color(.white.opacity(Self.stripePunchOpacity)))
                context.blendMode = .normal
                context.fill(stripes.center.applying(shift), with: .color(paceOnTop ? .green : .red))
            }
        }
        .frame(height: 6)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue("\(Int(clamped.rounded())) percent")
    }

    /// Sub-0.5 % renders empty and 99.5 %+ full, matching the rounded label.
    private static func renderedFillPercent(_ percent: Double) -> Double {
        let display = Int(percent.rounded())
        if display <= 0 { return 0 }
        if display >= 100 { return 100 }
        return percent
    }

    private static func clampedPercent(_ value: Double?) -> Double {
        guard let value else { return 0 }
        return min(100, max(0, value))
    }

    private static func paceStripePaths(size: CGSize, scale: CGFloat) -> (punched: Path, center: Path) {
        let align: (CGFloat) -> CGFloat = { ($0 * scale).rounded() / scale }
        let extend = size.height * 2
        let minY = align(-extend)
        let maxY = align(size.height + extend)
        let punchWidth = paceStripeWidth * 3
        let anchorX = align(size.width - 1 / scale)
        guard anchorX - punchWidth >= 0 else { return (Path(), Path()) }

        let punchRight = align(anchorX)
        let punchLeft = punchRight - punchWidth
        let punched = Path(CGRect(x: punchLeft, y: minY, width: punchWidth, height: maxY - minY))
        let centerLeft = align(punchLeft + (punchWidth - paceStripeWidth) / 2)
        let center = Path(CGRect(x: centerLeft, y: minY, width: paceStripeWidth, height: maxY - minY))
        return (punched, center)
    }
}
