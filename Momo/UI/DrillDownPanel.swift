//
//  DrillDownPanel.swift
//  The unified drop-down panel (OQ1): a metric picker + the selected metric's live detail
//  (per-core CPU, per-process attribution, sensor list) + a live graph (R3/R4). Opening the
//  panel drives the governor to DetailVisible so per-process + sensors collect only while a
//  panel is open (KTD3); closing it returns to MenuBarOnly.
//
//  viewTime seam (KTD12): the panel resolves its data through a `ViewTime` that is `.live` in
//  Phase 1 (ring buffer). U10's scrub-back is purely additive — it sets `.at(Date)` and adds the
//  historical branch behind this same seam rather than rewriting the panel.
//
import SwiftUI

// MARK: - View-time seam

/// What moment the panel renders. Phase 1 only ever resolves `.live`; U10 adds `.at`.
enum ViewTime: Equatable {
    case live
    case at(Date)
}

// MARK: - Drill targets

/// A metric the panel can drill into. Superset of the menu-bar metrics — includes Sensors,
/// which is a drill-down-only detail (not a menu-bar metric in v1).
enum DrillTarget: String, CaseIterable, Identifiable {
    case cpu, memory, disk, network, sensors
    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .disk: return "Disk"
        case .network: return "Network"
        case .sensors: return "Sensors"
        }
    }

    /// Which collectors the governor should run while this target's panel is visible (AE3).
    var visibleMetrics: CollectorSet {
        switch self {
        case .cpu: return [.cpu]
        case .memory: return [.memory]
        case .disk: return [.disk]
        case .network: return [.network]
        case .sensors: return [.sensors]
        }
    }

    /// Subsystem whose per-process attribution this target shows (nil = no per-process: network
    /// is system-wide per KTD6, sensors have none).
    var subsystem: Subsystem? {
        switch self {
        case .cpu: return .cpu
        case .memory: return .memory
        case .disk: return .disk
        case .network, .sensors: return nil
        }
    }

    var unit: MetricUnit {
        switch self {
        case .cpu: return .percent
        case .memory: return .percent
        case .disk, .network: return .bytesPerSecond
        case .sensors: return .celsius
        }
    }
}

// MARK: - Data resolution (the viewTime seam)

/// Resolves the panel's display sample + chart series for a `ViewTime`. Phase 1 implements only
/// `.live` (raw ring buffer); U10 adds the `.at` branch (historical via `HistoryQuery`).
enum PanelData {
    @MainActor static func sample(_ live: LiveModel, _ viewTime: ViewTime) -> Sample? {
        switch viewTime {
        case .live: return live.latest
        case .at: return live.latest   // Phase 2 (U10) resolves historical here.
        }
    }

    /// Recent series for `target` from the live ring (raw per-tick). U10 returns historical
    /// AVG/MAX points for `.at`.
    @MainActor static func series(_ live: LiveModel, _ viewTime: ViewTime, _ target: DrillTarget, window: Int = 120) -> [MetricPoint] {
        guard case .live = viewTime else { return [] }
        let samples = live.ring.recent(window)
        return samples.enumerated().compactMap { idx, s in
            guard let v = scalarValue(target, s) else { return nil }
            return MetricPoint(id: idx, time: s.timestamp, value: v)
        }
    }

    /// The scalar plotted for each target.
    static func scalarValue(_ target: DrillTarget, _ s: Sample) -> Double? {
        switch target {
        case .cpu:     return s.cpu?.overall
        case .memory:  return s.memory.map(MetricFormat.usedFraction)
        case .disk:    return s.disk.map { $0.readBytesPerSec + $0.writeBytesPerSec }
        case .network: return s.network.map { $0.rxBytesPerSec + $0.txBytesPerSec }
        case .sensors: return s.sensors?.temperatures.map(\.celsius).max()
        }
    }
}

// MARK: - Panel

/// Top-level MenuBarExtra content (OQ1 unified panel). Header + drill picker + detail/chart for
/// the selected target + footer (menu-bar metric toggles + Quit).
struct MomoPanel: View {
    let live: LiveModel
    let selection: MetricSelection
    let sensorCapability: SensorCapability?
    /// Toggles the governor's DetailVisible state. Injected so previews/tests don't touch the
    /// live governor.
    var setDetailVisible: (Bool, CollectorSet) -> Void = { visible, metrics in
        MomoServices.shared.governor.setDetailVisible(visible, metrics: metrics)
    }

    @State private var target: DrillTarget = .cpu
    @State private var viewTime: ViewTime = .live

    private var targets: [DrillTarget] {
        // Offer Sensors only if the machine exposes any (R12 — never an empty/zeroed tab).
        DrillTarget.allCases.filter { $0 != .sensors || (sensorCapability?.availableTemperatureCount ?? 0) > 0 }
    }

    var body: some View {
        let _ = live.tick
        let sample = PanelData.sample(live, viewTime)

        VStack(alignment: .leading, spacing: 10) {
            Text("Momo").font(.headline)

            Picker("Metric", selection: $target) {
                ForEach(targets) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            MetricChart(points: PanelData.series(live, viewTime, target),
                        unit: target.unit,
                        yDomainUpperBound: target == .cpu || target == .memory ? 1.0 : nil)

            DrillDetail(target: target, sample: sample, capability: sensorCapability)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .onAppear { setDetailVisible(true, target.visibleMetrics) }
        .onDisappear { setDetailVisible(false, []) }
        .onChange(of: target) { _, newTarget in setDetailVisible(true, newTarget.visibleMetrics) }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Show in menu bar").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(DisplayMetric.allCases) { metric in
                    Toggle(metric.label, isOn: Binding(
                        get: { selection.isSelected(metric) },
                        set: { _ in selection.toggle(metric) }))
                    .toggleStyle(.button).controlSize(.small)
                }
            }
            Button("Quit Momo") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
                .padding(.top, 2)
        }
    }
}

// MARK: - Per-target detail

private struct DrillDetail: View {
    let target: DrillTarget
    let sample: Sample?
    let capability: SensorCapability?

    var body: some View {
        switch target {
        case .cpu:     CPUDetail(sample: sample)
        case .memory:  ProcessList(subsystem: .memory, sample: sample, unit: .bytesValue, header: memoryHeader)
        case .disk:    ProcessList(subsystem: .disk, sample: sample, unit: .rate, header: diskHeader)
        case .network: NetworkDetail(sample: sample)
        case .sensors: SensorDetail(sample: sample, capability: capability)
        }
    }

    private var memoryHeader: String {
        guard let m = sample?.memory else { return "Memory" }
        return "\(MetricFormat.percent(MetricFormat.usedFraction(m))) used · \(MetricFormat.bytes(m.usedBytes)) of \(MetricFormat.bytes(m.totalBytes))"
    }
    private var diskHeader: String {
        guard let d = sample?.disk else { return "Disk" }
        return "↓\(MetricFormat.rate(d.readBytesPerSec))  ↑\(MetricFormat.rate(d.writeBytesPerSec))  ·  \(MetricFormat.bytes(d.freeBytes)) free"
    }
}

private struct CPUDetail: View {
    let sample: Sample?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let cpu = sample?.cpu {
                Text("\(MetricFormat.percent(cpu.overall)) overall · \(cpu.perCore.count) cores")
                    .font(.caption).foregroundStyle(.secondary)
                // Per-core mini bars.
                ForEach(Array(cpu.perCore.enumerated()), id: \.offset) { i, frac in
                    HStack(spacing: 6) {
                        Text("\(i)").font(.caption2.monospacedDigit()).frame(width: 16, alignment: .trailing)
                        ProgressView(value: min(max(frac, 0), 1))
                        Text(MetricFormat.percent(frac)).font(.caption2.monospacedDigit())
                            .frame(width: 38, alignment: .trailing)
                    }
                }
            } else {
                CollectingRow()
            }
            ProcessList(subsystem: .cpu, sample: sample, unit: .percent, header: nil)
        }
    }
}

private struct NetworkDetail: View {
    let sample: Sample?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let n = sample?.network {
                Label("Download \(MetricFormat.rate(n.rxBytesPerSec))", systemImage: "arrow.down")
                Label("Upload \(MetricFormat.rate(n.txBytesPerSec))", systemImage: "arrow.up")
                Text("Per-process network is system-wide only (no per-app attribution).")
                    .font(.caption2).foregroundStyle(.secondary).padding(.top, 2)
            } else {
                CollectingRow()
            }
        }
        .font(.callout)
    }
}

private struct SensorDetail: View {
    let sample: Sample?
    let capability: SensorCapability?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let cap = capability {
                // OQ6: "N of M available on this Mac".
                Text("\(cap.availableTemperatureCount) of \(cap.expectedTemperatureCount) temperature sensors available on this Mac")
                    .font(.caption).foregroundStyle(.secondary)
            }
            let temps = sample?.sensors?.temperatures ?? []
            if temps.isEmpty {
                CollectingRow()
            } else {
                ForEach(temps.prefix(12)) { t in
                    HStack {
                        Text(t.label).lineLimit(1)
                        Spacer()
                        Text(String(format: "%.1f°C", t.celsius)).monospacedDigit().foregroundStyle(.secondary)
                    }.font(.callout)
                }
            }
        }
    }
}

/// A ranked top-process list for a subsystem (CPU/memory/disk). Network/sensors don't use it.
private struct ProcessList: View {
    enum Unit { case percent, bytesValue, rate }
    let subsystem: Subsystem
    let sample: Sample?
    let unit: Unit
    let header: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let header { Text(header).font(.caption).foregroundStyle(.secondary) }
            let rows = sample?.attribution?.bySubsystem[subsystem]
            if let rows {
                if rows.isEmpty {
                    Text("No significant processes.").font(.caption2).foregroundStyle(.secondary)
                } else {
                    ForEach(rows) { row in
                        HStack {
                            Text(row.restricted ? "\(row.name) (restricted)" : row.name).lineLimit(1)
                            Spacer()
                            Text(format(row.value)).monospacedDigit().foregroundStyle(.secondary)
                        }.font(.callout)
                    }
                }
            } else {
                CollectingRow()   // detail tick not arrived yet (sub-cadence) — OQ3.
            }
        }
    }

    private func format(_ v: Double) -> String {
        switch unit {
        case .percent:    return MetricFormat.percent(v)
        case .bytesValue: return MetricFormat.bytes(UInt64(max(0, v)))
        case .rate:       return MetricFormat.rate(v)
        }
    }
}

private struct CollectingRow: View {
    var body: some View {
        Text("Collecting data…").font(.caption).foregroundStyle(.secondary)
    }
}
