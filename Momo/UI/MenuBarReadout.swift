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

// The unified drop-down panel now lives in DrillDownPanel.swift (`MomoPanel`), which
// supersedes U7's readout-only panel with per-metric drill-down + live graphs (U8).
