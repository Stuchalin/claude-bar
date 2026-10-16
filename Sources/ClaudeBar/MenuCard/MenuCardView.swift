// Layout and styling adapted from CodexBar (https://github.com/steipete/CodexBar),
// Sources/CodexBar/MenuCardView.swift, MenuCardMetricRow.swift, UsageMenuCardLayout.swift,
// UsageMenuCardHeaderAndUsageSectionView.swift and MenuCardView+Costs.swift at commit a91669f.
// Copyright (c) 2026 Peter Steinberger. MIT License; see THIRD_PARTY_NOTICES.md.

import AppKit
import ClaudeBarCore
import SwiftUI

/// CodexBar's card layout constants (`UsageMenuCardLayout.swift`) and menu width.
enum MenuCardLayout {
    static let width: CGFloat = 310
    static let horizontalPadding: CGFloat = 20
    static let verticalPadding: CGFloat = 6
    static let headerContentSpacing: CGFloat = 6
    static let headerLineSpacing: CGFloat = 4
    static let postHeaderDividerSpacing: CGFloat = 6 + 10
    static let metricSpacing: CGFloat = 12
    /// Claude accent, RGB(204, 124, 94) (CodexBar `ClaudeProviderDescriptor.swift`).
    static let accent = Color(red: 204 / 255, green: 124 / 255, blue: 94 / 255)
    static let staleTint = Color(nsColor: .secondaryLabelColor)
}

/// The whole Claude card hosted in one `NSMenuItem`: header, quota rows and Extra usage.
struct MenuCardView: View {
    let model: MenuCardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuCardHeader(header: model.header)
            Divider()
                .padding(.top, MenuCardLayout.headerContentSpacing)
                .padding(.bottom, MenuCardLayout.postHeaderDividerSpacing)
            VStack(alignment: .leading, spacing: MenuCardLayout.metricSpacing) {
                ForEach(model.metrics) { metric in
                    MenuCardMetricRow(metric: metric)
                }
                if let extra = model.extra {
                    Divider()
                    MenuCardExtraRow(extra: extra)
                }
            }
        }
        .padding(.horizontal, MenuCardLayout.horizontalPadding)
        .padding(.vertical, MenuCardLayout.verticalPadding)
        .frame(width: MenuCardLayout.width, alignment: .leading)
    }
}

private struct MenuCardHeader: View {
    let header: MenuCardModel.Header

    var body: some View {
        VStack(alignment: .leading, spacing: MenuCardLayout.headerLineSpacing) {
            Text(header.title)
                .font(.headline)
                .fontWeight(.semibold)
                .lineLimit(1)
            Text(header.subtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let error = header.errorText {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct MenuCardMetricRow: View {
    let metric: MenuCardModel.Metric

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch metric.content {
            case let .status(text):
                Text(metric.title)
                    .font(.body)
                    .fontWeight(.medium)
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            case let .usage(usage):
                header(usage)
                UsageProgressBar(
                    percent: usage.percentLeft,
                    tint: usage.staleText == nil ? MenuCardLayout.accent : MenuCardLayout.staleTint,
                    accessibilityLabel: "\(metric.title) usage remaining",
                    pacePercent: usage.pacePercent,
                    paceOnTop: usage.paceOnTop
                )
                if let pace = usage.paceText {
                    footnote(pace)
                        .help("Average pace since the window started")
                        .accessibilityLabel("Average pace since the window started: \(pace)")
                }
                if let stale = usage.staleText {
                    footnote(stale)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func header(_ usage: MenuCardModel.Usage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(metric.title) \(usage.percentText)")
                .font(.body)
                .fontWeight(.medium)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 8)
            Text(usage.resetText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct MenuCardExtraRow: View {
    let extra: MenuCardModel.Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(extra.title)
                .font(.body)
                .fontWeight(.medium)
                .lineLimit(1)
            if let percentLeft = extra.percentLeft {
                UsageProgressBar(
                    percent: percentLeft,
                    tint: extra.staleText == nil ? MenuCardLayout.accent : MenuCardLayout.staleTint,
                    accessibilityLabel: "Extra usage remaining"
                )
            }
            HStack(alignment: .firstTextBaseline) {
                Text(extra.spendText)
                    .font(.footnote)
                    .monospacedDigit()
                    .lineLimit(1)
                Spacer()
                if let percentText = extra.percentText {
                    Text(percentText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if let note = extra.noteText {
                secondary(note)
            }
            if let stale = extra.staleText {
                secondary(stale)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func secondary(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}
