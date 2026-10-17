// Chart styling adapted from CodexBar (https://github.com/steipete/CodexBar),
// Sources/CodexBar/QuotaBurndownChartMenuView.swift and PlanUtilizationHistoryChartMenuView.swift at
// commit a91669f: dashed ideal line, 2 pt observed line with a current point, 0/50/100 axis, start
// and reset labels; capped 6 pt bars on a track, 30 slots, segmented series picker, 130 pt charts.
// Copyright (c) 2026 Peter Steinberger. MIT License; see THIRD_PARTY_NOTICES.md.

import AppKit
import Charts
import ClaudeBarCore
import SwiftUI

enum UsageHistoryLayout {
    static let width = MenuCardLayout.width
    static let horizontalPadding: CGFloat = 16
    static let verticalPadding: CGFloat = 10
    static let sectionSpacing: CGFloat = 8
    static let pickerHeight: CGFloat = 24
    static let chartHeight: CGFloat = 130
    static let axisLabelHeight: CGFloat = 30
    static let captionHeight: CGFloat = 16
    static let barWidth: CGFloat = 6
    /// Burn-down: chart, start/reset labels and the latest-value caption.
    static let burndownHeight = chartHeight + axisLabelHeight + captionHeight + 2 * 4
    /// Peaks: chart, oldest/newest labels and the detail caption.
    static let peaksHeight = chartHeight + captionHeight + captionHeight + 2 * 4
    static let track = Color(nsColor: .tertiaryLabelColor).opacity(0.22)
}

/// The "Usage history" submenu content: one series picker, the current window's burn-down and the
/// observed peak of each past window. Every state keeps the same height, so the hosting menu item
/// never needs resizing while the menu is open.
struct UsageHistoryMenuView: View {
    let model: UsageHistoryMenuModel

    var body: some View {
        VStack(alignment: .leading, spacing: UsageHistoryLayout.sectionSpacing) {
            if model.isFixture {
                Text("Fixture data — not your recorded history")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color(nsColor: .systemOrange))
            }
            header
                .frame(height: UsageHistoryLayout.pickerHeight)
            sectionTitle("Current window")
            burndownSection
                .frame(height: UsageHistoryLayout.burndownHeight, alignment: .top)
            Divider()
            sectionTitle("Observed peak per past window")
            peaksSection
                .frame(height: UsageHistoryLayout.peaksHeight, alignment: .top)
        }
        .padding(.horizontal, UsageHistoryLayout.horizontalPadding)
        .padding(.vertical, UsageHistoryLayout.verticalPadding)
        .frame(width: UsageHistoryLayout.width, alignment: .leading)
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        if case let .loaded(charts) = model.state, charts.series.count > 1 {
            let picker = Picker(selection: Binding(
                get: { model.selectedSeries?.id ?? "" },
                set: { model.selectedSeriesID = $0 }
            )) {
                ForEach(charts.series) { series in
                    Text(series.title).tag(series.id)
                }
            } label: {
                EmptyView()
            }
            .labelsHidden()
            if charts.series.count <= 3 {
                picker.pickerStyle(.segmented)
            } else {
                picker.pickerStyle(.menu)
            }
        } else {
            Text(model.selectedSeries?.title ?? "Usage history")
                .font(.body)
                .fontWeight(.medium)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    // MARK: - Burn-down

    @ViewBuilder
    private var burndownSection: some View {
        if let message = placeholderMessage {
            placeholder(message)
        } else if let series = model.selectedSeries {
            switch series.burndown {
            case let .chart(chart):
                BurndownChart(chart: chart)
            case .noObservations:
                placeholder("No \(series.title.lowercased()) observations yet")
            case .noCurrentWindow:
                placeholder("No observations in the current \(series.title.lowercased()) window")
            }
        }
    }

    // MARK: - Peaks

    @ViewBuilder
    private var peaksSection: some View {
        if let message = placeholderMessage {
            placeholder(message)
        } else if let series = model.selectedSeries {
            if series.peaks.slots.isEmpty {
                placeholder("No past \(series.title.lowercased()) windows observed yet")
            } else {
                PeakChart(peaks: series.peaks, isSession: series.metric == .session)
            }
        }
    }

    /// Text for states without a series to draw.
    private var placeholderMessage: String? {
        switch model.state {
        case .loading: "Loading history…"
        case .notConfigured: "Set the proxy URL in Settings to record history"
        case let .failed(message): message
        case let .loaded(charts): charts.series.isEmpty ? "No history recorded yet" : nil
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Remaining share in the current window: dashed ideal line, observed pieces, latest point.
private struct BurndownChart: View {
    let chart: BurndownChartModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Chart {
                ForEach(Array(chart.ideal.enumerated()), id: \.offset) { _, point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Usage remaining", point.remainingPercent),
                        series: .value("Line", "Ideal")
                    )
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
                ForEach(chart.segments) { segment in
                    ForEach(Array(segment.samples.enumerated()), id: \.offset) { _, point in
                        LineMark(
                            x: .value("Time", point.date),
                            y: .value("Usage remaining", point.remainingPercent),
                            series: .value("Line", "Observed \(segment.id)")
                        )
                        .foregroundStyle(MenuCardLayout.accent)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    if segment.samples.count == 1, let point = segment.samples.first {
                        PointMark(
                            x: .value("Time", point.date),
                            y: .value("Usage remaining", point.remainingPercent)
                        )
                        .foregroundStyle(MenuCardLayout.accent)
                        .symbolSize(12)
                    }
                }
                PointMark(
                    x: .value("Time", chart.latest.date),
                    y: .value("Usage remaining", chart.latest.remainingPercent)
                )
                .foregroundStyle(MenuCardLayout.accent)
                .symbolSize(35)
            }
            .chartXScale(domain: chart.start...chart.reset)
            .chartYScale(domain: 0...100)
            .chartYAxis { AxisMarks(values: [0, 50, 100]) }
            .chartXAxis(.hidden)
            .chartLegend(.hidden)
            .frame(height: UsageHistoryLayout.chartHeight)
            .accessibilityLabel("Usage remaining in the current window")
            .accessibilityValue(UsageFormatter.percentText(chart.latest.remainingPercent, suffix: "left"))

            HStack(alignment: .top) {
                axisLabel(chart.start, alignment: .leading)
                Spacer()
                axisLabel(chart.reset, alignment: .trailing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(height: UsageHistoryLayout.axisLabelHeight, alignment: .top)

            Text("Last observed \(chart.latest.date.formatted(date: .omitted, time: .shortened)): "
                + UsageFormatter.percentText(chart.latest.remainingPercent, suffix: "left"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(height: UsageHistoryLayout.captionHeight, alignment: .leading)
        }
    }

    private var spansDays: Bool { chart.reset.timeIntervalSince(chart.start) >= 86400 }

    private func axisLabel(_ date: Date, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            if spansDays {
                Text(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
            }
            Text(date.formatted(date: .omitted, time: .shortened))
        }
        .accessibilityElement(children: .combine)
    }
}

/// One capped bar per observed past window; unobserved stretches are a dashed rule, never a bar.
private struct PeakChart: View {
    let peaks: PeakChartModel
    let isSession: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Chart {
                ForEach(Array(peaks.slots.enumerated()), id: \.offset) { index, slot in
                    if case let .observed(window) = slot {
                        BarMark(
                            x: .value("Window", Double(index)),
                            yStart: .value("Capacity start", 0),
                            yEnd: .value("Capacity end", 100),
                            width: .fixed(UsageHistoryLayout.barWidth)
                        )
                        .foregroundStyle(UsageHistoryLayout.track)
                        BarMark(
                            x: .value("Window", Double(index)),
                            yStart: .value("Observed peak start", 0),
                            yEnd: .value("Observed peak", min(100, max(0, window.peakUsedPercent))),
                            width: .fixed(UsageHistoryLayout.barWidth)
                        )
                        .foregroundStyle(MenuCardLayout.accent)
                    } else {
                        RuleMark(
                            x: .value("Window", Double(index)),
                            yStart: .value("Not observed start", 0),
                            yEnd: .value("Not observed end", 100)
                        )
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    }
                }
            }
            .chartXScale(domain: -0.5...(Double(PeakChartModel.maxSlots) - 0.5))
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .frame(height: UsageHistoryLayout.chartHeight)
            .accessibilityLabel("Observed peak usage per past window")
            .accessibilityValue("\(peaks.observedWindows.count) observed windows")

            HStack {
                if let oldest = peaks.observedWindows.first {
                    Text(label(oldest.resetAt))
                }
                Spacer()
                if let newest = peaks.observedWindows.last, peaks.observedWindows.count > 1 {
                    Text(label(newest.resetAt))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(height: UsageHistoryLayout.captionHeight)

            Text(PeakChartModel.detailText(peaks.slots.last, date: label))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(height: UsageHistoryLayout.captionHeight, alignment: .leading)
        }
    }

    private func label(_ date: Date) -> String {
        isSession
            ? date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
            : date.formatted(.dateTime.month(.abbreviated).day())
    }
}
