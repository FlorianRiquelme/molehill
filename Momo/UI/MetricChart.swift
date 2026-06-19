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

    var body: some View {
        Group {
            if points.count < 2 {
                // OQ3: nothing to plot yet.
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.3))
                    Text("Collecting data…").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Chart(points) { p in
                    LineMark(x: .value("Time", p.time), y: .value("Value", p.value))
                        .interpolationMethod(.monotone)
                    // Aggregated MAX overlay (Phase 2 historical points only).
                    if let mx = p.valueMax {
                        LineMark(x: .value("Time", p.time), y: .value("Max", mx),
                                 series: .value("Series", "max"))
                            .foregroundStyle(.secondary)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
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
                .drawingGroup()   // smoother while on screen (R11/U8)
            }
        }
        .frame(height: 92)
    }

    private var yDomain: ClosedRange<Double> {
        if let upper = yDomainUpperBound { return 0...upper }
        let values = points.flatMap { [$0.value, $0.valueMax ?? $0.value] }
        let hi = values.max() ?? 1
        return 0...(hi <= 0 ? 1 : hi * 1.15)
    }
}
