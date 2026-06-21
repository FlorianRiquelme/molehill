//
//  MetricChart.swift
//  Live Swift Charts line over a bounded rolling in-memory window (R4). Phase 1 renders raw
//  per-tick values from the ring buffer; Phase 2 (U10) feeds the same view historical bucket
//  points (AVG + optional MAX) behind the panel's viewTime seam, so this view is written to
//  accept either.
//
import SwiftUI
import Charts

/// One plotted point. `valueMax` is non-nil only for aggregated historical points (Phase 2),
/// where MAX is surfaced alongside AVG so a spike isn't lost to averaging (KTD12).
struct MetricPoint: Identifiable, Equatable {
    let id: Int
    let time: Date
    let value: Double
    var valueMax: Double? = nil
}

/// How to format the Y axis / value labels for a metric.
enum MetricUnit {
    case percent
    case bytesPerSecond
    case celsius

    func string(_ v: Double) -> String {
        switch self {
        case .percent:        return MetricFormat.percent(v)
        case .bytesPerSecond: return MetricFormat.rate(v)
        case .celsius:        return String(format: "%.0f°", v)
        }
    }
}

struct MetricChart: View {
    let points: [MetricPoint]
    let unit: MetricUnit
    /// 0...1 for percent metrics; nil lets Charts auto-scale (rates/temps).
    var yDomainUpperBound: Double? = nil
    /// Visible X span in seconds when scrubbing history; nil = no horizontal scroll (live path).
    /// When set (U10 `.at`), the chart becomes horizontally scrollable over the historical
    /// window and scrolls to `scrollPosition` so the cursor's window is shown (macOS 14+).
    var scrubVisibleSeconds: TimeInterval? = nil
    /// Binding for the scrolled-to leading X (a `Date`). Drives `chartScrollPosition`.
    @Binding var scrollPosition: Date
    /// U11 will bind a selected X (`Date?`) here via `chartXSelection` to drive culprit lookup;
    /// left nil in U10 (see note below). Optional binding so the live path passes none.
    var selection: Binding<Date?>? = nil

    init(points: [MetricPoint], unit: MetricUnit, yDomainUpperBound: Double? = nil,
         scrubVisibleSeconds: TimeInterval? = nil,
         scrollPosition: Binding<Date> = .constant(.distantPast),
         selection: Binding<Date?>? = nil) {
        self.points = points
        self.unit = unit
        self.yDomainUpperBound = yDomainUpperBound
        self.scrubVisibleSeconds = scrubVisibleSeconds
        self._scrollPosition = scrollPosition
        self.selection = selection
    }

    var body: some View {
        Group {
            if points.count < 2 {
                // OQ3: nothing to plot yet.
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.3))
                    Text("Collecting data…").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                chart
            }
        }
        .frame(height: 92)
    }

    @ViewBuilder
    private var chart: some View {
        let base = Chart(points) { p in
            LineMark(x: .value("Time", p.time), y: .value("Value", p.value))
                .interpolationMethod(.monotone)
            // Aggregated MAX overlay (Phase 2 historical points only).
            if let mx = p.valueMax {
                LineMark(x: .value("Time", p.time), y: .value("Max", mx),
                         series: .value("Series", "max"))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            // U11: a vertical RuleMark at the selected x marks the moment whose culprits the
            // panel resolves. Works on both the live (static) and scrub (scrollable) charts.
            if let selected = selection?.wrappedValue {
                RuleMark(x: .value("Selected", selected))
                    .foregroundStyle(.primary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartYScale(domain: yDomain)
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let d = value.as(Double.self) { Text(unit.string(d)) }
                }
            }
        }
        .chartXAxis(.hidden)

        // U11: point selection (R9 causal drill-down). `chartXSelection` gives the selected
        // `Date`; the panel maps it to ts and resolves the responsible processes. Applied on
        // both paths (selection works on a static chart too) when a binding is supplied.
        let selectable = applySelection(base)

        // Historical (scrub) path: horizontal scroll over the recorded window with a fixed
        // visible span and a programmatic scroll position (macOS 14+).
        if let visible = scrubVisibleSeconds {
            selectable
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: visible)
                .chartScrollPosition(x: $scrollPosition)
        } else {
            // Live path: no scroll. `drawingGroup()` is dropped here because it rasterizes the
            // chart into an image layer that swallows the gesture `chartXSelection` needs; the
            // bounded live window is cheap enough to render directly (R11/U8).
            selectable
        }
    }

    /// Attach `.chartXSelection(value:)` only when a selection binding is supplied (the live
    /// path with no culprit lookup passes none), so the modifier's generic type stays resolved.
    @ViewBuilder
    private func applySelection(_ chart: some View) -> some View {
        if let selection {
            chart.chartXSelection(value: selection)
        } else {
            chart
        }
    }

    private var yDomain: ClosedRange<Double> {
        if let upper = yDomainUpperBound { return 0...upper }
        let values = points.flatMap { [$0.value, $0.valueMax ?? $0.value] }
        let hi = values.max() ?? 1
        return 0...(hi <= 0 ? 1 : hi * 1.15)
    }
}
