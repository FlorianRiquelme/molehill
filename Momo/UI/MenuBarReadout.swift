//
//  MenuBarReadout.swift
//  Glanceable menu-bar label + the unified drop-down panel (OQ1: single combined item + one
//  panel with a metric picker). Plain text/number readouts — pre-attentive glyphs/sparklines
//  are deferred (origin scope). Updates on new live data, not a render clock (R2).
//
import SwiftUI

// MARK: - Formatting

enum MetricFormat {
    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    static func rate(_ bytesPerSec: Double) -> String {
        byteString(bytesPerSec) + "/s"
    }

    static func bytes(_ count: UInt64) -> String { byteString(Double(count)) }

    private static func byteString(_ value: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = max(0, value)
        var i = 0
        while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        return i == 0 ? "\(Int(v)) \(units[i])" : String(format: "%.1f %@", v, units[i])
    }

    /// Compact value for the menu-bar label (glyph + value).
    static func compact(_ metric: DisplayMetric, _ s: Sample?) -> String {
        switch metric {
        case .cpu:     return s?.cpu.map { percent($0.overall) } ?? "–"
        case .memory:  return s?.memory.map { percent(usedFraction($0)) } ?? "–"
        case .disk:    return s?.disk.map { rate($0.readBytesPerSec + $0.writeBytesPerSec) } ?? "–"
        case .network: return s?.network.map { rate($0.rxBytesPerSec + $0.txBytesPerSec) } ?? "–"
        }
    }

    static func usedFraction(_ m: MemorySample) -> Double {
        m.totalBytes == 0 ? 0 : Double(m.usedBytes) / Double(m.totalBytes)
    }
}

// MARK: - Menu-bar label

/// The compact label rendered in the menu bar for the selected subset (R2).
struct MenuBarLabel: View {
    let live: LiveModel
    let selection: MetricSelection

    var body: some View {
        // Touch `live.tick` so the label re-renders each new sample.
        let _ = live.tick
        let sample = live.latest
        if selection.selected.isEmpty {
            Text("Momo")
        } else {
            Text(selection.selected
                .map { "\($0.glyph) \(MetricFormat.compact($0, sample))" }
                .joined(separator: "  "))
        }
    }
}

// MARK: - Unified panel

/// The drop-down panel: live values for every metric + the menu-bar metric picker + Quit
/// (OQ1 unified panel). The drill-down graphs/per-process detail land in U8.
struct ReadoutPanel: View {
    let live: LiveModel
    let selection: MetricSelection

    var body: some View {
        let _ = live.tick
        let sample = live.latest

        VStack(alignment: .leading, spacing: 12) {
            Text("Momo").font(.headline)

            if sample == nil {
                // OQ3 first-run state.
                Text("Collecting data…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(DisplayMetric.allCases) { metric in
                        MetricRow(metric: metric, sample: sample, selection: selection)
                    }
                }
            }

            Divider()
            Text("Show in menu bar").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(DisplayMetric.allCases) { metric in
                    Toggle(metric.label, isOn: Binding(
                        get: { selection.isSelected(metric) },
                        set: { _ in selection.toggle(metric) }))
                    .toggleStyle(.button)
                    .controlSize(.small)
                }
            }

            Divider()
            Button("Quit Momo") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
    }
}

private struct MetricRow: View {
    let metric: DisplayMetric
    let sample: Sample?
    let selection: MetricSelection

    var body: some View {
        HStack {
            Text(metric.label)
                .fontWeight(selection.isSelected(metric) ? .semibold : .regular)
            Spacer()
            Text(detail)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var detail: String {
        switch metric {
        case .cpu:
            return sample?.cpu.map { MetricFormat.percent($0.overall) } ?? "n/a"
        case .memory:
            guard let m = sample?.memory else { return "n/a" }
            return "\(MetricFormat.percent(MetricFormat.usedFraction(m))) · \(MetricFormat.bytes(m.usedBytes))"
        case .disk:
            guard let d = sample?.disk else { return "n/a" }
            return "↓\(MetricFormat.rate(d.readBytesPerSec)) ↑\(MetricFormat.rate(d.writeBytesPerSec))"
        case .network:
            guard let n = sample?.network else { return "n/a" }
            return "↓\(MetricFormat.rate(n.rxBytesPerSec)) ↑\(MetricFormat.rate(n.txBytesPerSec))"
        }
    }
}
