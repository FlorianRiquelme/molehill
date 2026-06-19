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
import GRDB

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

    /// The AVG / MAX scalar plotted for this target from a recorded `ScalarRow` (KTD12 dual-path:
    /// historical points are bucket aggregates, so MAX is surfaced alongside AVG). Mirrors the
    /// live `PanelData.scalarValue` plot but reads the recorded columns:
    ///   cpu→cpu_avg/cpu_max, memory→used fraction (used/total), disk→read+write, network→rx+tx,
    ///   sensors→hottest temp (temp_max_avg/temp_max_max). `avg` is nil only when the bucket has
    ///   no value for the metric (a NULL-metric present row → no plotted point for this target).
    func historicalScalar(_ r: ScalarRow) -> (avg: Double, max: Double?)? {
        switch self {
        case .cpu:
            guard let avg = r.cpuAvg else { return nil }
            return (avg, r.cpuMax)
        case .memory:
            // Fraction used = used / total, mirroring MetricFormat.usedFraction on the live path.
            // Clamp to <=1.0 so the MAX overlay can't clip against the chart's 0...1 domain.
            guard let total = r.memTotal, total > 0 else { return nil }
            guard let avg = r.memUsedAvg.map({ min($0 / total, 1.0) }) else { return nil }
            return (avg, r.memUsedMax.map { min($0 / total, 1.0) })
        case .disk:
            // Combined throughput = read + write. AVG is sum of AVGs; MAX is sum of MAXes (an
            // upper bound on combined throughput — read and write peaks may not coincide).
            let avg = (r.diskReadAvg ?? 0) + (r.diskWriteAvg ?? 0)
            guard r.diskReadAvg != nil || r.diskWriteAvg != nil else { return nil }
            let mx = r.diskReadMax != nil || r.diskWriteMax != nil
                ? (r.diskReadMax ?? 0) + (r.diskWriteMax ?? 0) : nil
            return (avg, mx)
        case .network:
            let avg = (r.netRxAvg ?? 0) + (r.netTxAvg ?? 0)
            guard r.netRxAvg != nil || r.netTxAvg != nil else { return nil }
            let mx = r.netRxMax != nil || r.netTxMax != nil
                ? (r.netRxMax ?? 0) + (r.netTxMax ?? 0) : nil
            return (avg, mx)
        case .sensors:
            guard let avg = r.tempMaxAvg else { return nil }
            return (avg, r.tempMaxMax)
        }
    }
}

// MARK: - Historical resolution (the .at branch, testable without UI)

/// Resolves a `DrillTarget`'s chart series + cursor reading from recorded history for a
/// `ViewTime.at(date)`, behind the panel's seam (U10). Pure aside from the GRDB read it is
/// handed — so AE1 is unit-testable by constructing a `HistoryQuery` over a populated
/// `RecordingStore.temporary()` and asserting the resolved values are the RECORDED ones, not
/// the current live ones.
///
/// The read runs on GRDB's reader pool (never the writer), so a parked scrubber holds a
/// consistent WAL snapshot and never blocks ingest — the historical read is independent of
/// live collection cadence (governor stays DetailVisible, but ingest is untouched).
enum HistoricalResolver {
    /// The resolved state for `.at(date)`: the chart series (AVG line + MAX overlay) and the
    /// reading at the cursor, plus the gap/truncation state for the scrubber + panel body.
    struct Resolution: Equatable {
        var points: [MetricPoint]
        /// The recorded scalar at (or nearest at-or-before) the cursor, for the detail header.
        /// nil when the cursor is parked in a gap (OQ5 — "device was asleep").
        var cursorValue: Double?
        var cursorValueMax: Double?
        /// True when the cursor's timestamp falls inside a recorded gap (no row) — OQ5.
        var cursorInGap: Bool
        var frame: ScrubFrame
    }

    /// How wide a window to load around the cursor (centered). The chart shows this window and
    /// the cursor scrubs within it; widening drops to a coarser tier automatically (U9).
    static let defaultWindow: TimeInterval = 60 * 60   // 1 hour

    /// Resolve `date` against `query`. `window` is the total span shown (cursor centered).
    /// Throws only on a GRDB read failure; an empty/clamped range resolves to a gap state.
    static func resolve(
        date: Date,
        target: DrillTarget,
        query: HistoryQuery,
        window: TimeInterval = defaultWindow,
        now: Date = Date()
    ) throws -> Resolution {
        let cursorTs = Int(date.timeIntervalSince1970)
        let nowTs = Int(now.timeIntervalSince1970)
        // Center the window on the cursor, but never show the future past `now`.
        let half = Int(window / 2)
        // End is half-open in the query; include the cursor's own bucket (+1) so scrubbing to the
        // live edge resolves the most recent recorded second, and never show past `now`.
        let end = min(max(cursorTs + half, cursorTs + 1), nowTs + 1)
        let start = end - Int(window)
        let series = try query.series(start: start, end: end, now: nowTs)
        return resolution(from: series, target: target, cursorTs: cursorTs)
    }

    /// Build a `Resolution` from an already-fetched `HistorySeries` (separated so it is testable
    /// against a hand-built series with no DB).
    static func resolution(from series: HistorySeries, target: DrillTarget, cursorTs: Int) -> Resolution {
        var points: [MetricPoint] = []
        var idx = 0
        var gaps: [ScrubGap] = []

        let windowStartTs = series.resolvedStart
        let windowEndTs = series.resolvedEnd
        let span = Double(max(1, windowEndTs - windowStartTs))
        func fraction(_ ts: Int) -> Double {
            min(max(Double(ts - windowStartTs) / span, 0), 1)
        }

        for point in series.points {
            switch point {
            case .sample(let row):
                // A present row with no value for this target (NULL metric) yields no point —
                // the chart simply has no mark there, distinct from a `.gap` break.
                if let s = target.historicalScalar(row) {
                    points.append(MetricPoint(
                        id: idx,
                        time: Date(timeIntervalSince1970: Double(row.ts)),
                        value: s.avg,
                        valueMax: s.max))
                }
                idx += 1
            case .gap(let from, let to):
                gaps.append(ScrubGap(startFraction: fraction(from), endFraction: fraction(to)))
            }
        }

        // Cursor reading: the recorded sample at-or-before the cursor, within this window. If the
        // nearest preceding boundary is a gap (cursor parked in a recorded gap), report the gap.
        let cursorInGap = series.points.contains { point in
            if case .gap(let from, let to) = point { return cursorTs >= from && cursorTs < to }
            return false
        }
        var cursorValue: Double?
        var cursorValueMax: Double?
        if !cursorInGap {
            // Nearest sample at-or-before the cursor (the value "as recorded at that timestamp").
            for point in series.points.reversed() {
                if case .sample(let row) = point, row.ts <= cursorTs,
                   let s = target.historicalScalar(row) {
                    cursorValue = s.avg
                    cursorValueMax = s.max
                    break
                }
            }
        }

        let frame = ScrubFrame(
            windowStart: Date(timeIntervalSince1970: Double(windowStartTs)),
            windowEnd: Date(timeIntervalSince1970: Double(windowEndTs)),
            gaps: gaps,
            truncatedToOldest: series.truncatedToOldest)

        return Resolution(
            points: points,
            cursorValue: cursorValue,
            cursorValueMax: cursorValueMax,
            cursorInGap: cursorInGap,
            frame: frame)
    }
}

// MARK: - Data resolution (the viewTime seam)

/// Resolves the panel's LIVE display sample + chart series (raw ring buffer). The `.at`
/// (historical) branch is resolved by `HistoricalResolver` off the GRDB reader pool — kept
/// separate from this synchronous live path so a DB read never blocks the live render (KTD12).
enum PanelData {
    @MainActor static func sample(_ live: LiveModel, _ viewTime: ViewTime) -> Sample? {
        switch viewTime {
        case .live: return live.latest
        case .at: return nil   // historical detail comes from HistoricalResolver, not the ring.
        }
    }

    /// Recent series for `target` from the live ring (raw per-tick). `.at` returns nothing here —
    /// the panel feeds the chart `HistoricalResolver`-resolved points instead.
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
    /// Reader pool for historical (`.at`) reads. Defaults to the live store; nil disables
    /// scrub-back (e.g. recording failed to open) so the scrubber simply doesn't appear.
    var dbPool: DatabasePool? = MomoServices.shared.store?.dbPool

    @State private var target: DrillTarget = .cpu
    @State private var viewTime: ViewTime = .live
    /// Resolved historical state for the current `.at` cursor, loaded off-main via `.task(id:)`.
    @State private var historical: HistoricalResolver.Resolution?
    /// Leading X of the chart's visible scroll window (drives `chartScrollPosition`).
    @State private var scrollPosition: Date = .distantPast
    /// U11: the point selected on the graph (`chartXSelection`). nil = nothing selected; the
    /// detail body shows the normal scalar detail. When set, the panel resolves and shows the
    /// responsible processes for that moment (R9 causal drill-down).
    @State private var selectedTime: Date?
    /// Resolved culprits for `selectedTime` (loaded off-main for the historical read).
    @State private var culprit: CulpritResult?

    private var targets: [DrillTarget] {
        // Offer Sensors only if the machine exposes any (R12 — never an empty/zeroed tab).
        DrillTarget.allCases.filter { $0 != .sensors || (sensorCapability?.availableTemperatureCount ?? 0) > 0 }
    }

    /// True once a panel can scrub (a reader pool exists). The scrubber only shows then.
    private var scrubAvailable: Bool { dbPool != nil }

    var body: some View {
        let _ = live.tick
        let isHistorical = { if case .at = viewTime { return true }; return false }()
        // Live path stays synchronous off the ring; historical comes from `.task`-loaded state.
        let sample = isHistorical ? nil : PanelData.sample(live, viewTime)
        let points = isHistorical
            ? (historical?.points ?? [])
            : PanelData.series(live, viewTime, target)

        VStack(alignment: .leading, spacing: 10) {
            Text("Momo").font(.headline)

            Picker("Metric", selection: $target) {
                ForEach(targets) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            MetricChart(points: points,
                        unit: target.unit,
                        yDomainUpperBound: target == .cpu || target == .memory ? 1.0 : nil,
                        scrubVisibleSeconds: isHistorical ? HistoricalResolver.defaultWindow : nil,
                        scrollPosition: $scrollPosition,
                        selection: $selectedTime)

            // Scrubber timeline (OQ4) — only when scrub-back is available and a window resolved.
            if scrubAvailable, let frame = historical?.frame {
                Scrubber(frame: frame, viewTime: viewTime,
                         onScrub: { date in viewTime = .at(date) },
                         onReturnToLive: { viewTime = .live; historical = nil })
            } else if scrubAvailable {
                // Live: a thin entry point — tapping the track begins scrubbing one window back.
                Button {
                    viewTime = .at(Date().addingTimeInterval(-HistoricalResolver.defaultWindow / 2))
                } label: {
                    Label("Scrub history", systemImage: "clock.arrow.circlepath")
                        .font(.caption2)
                }
                .buttonStyle(.borderless).controlSize(.small)
            }

            detailBody(isHistorical: isHistorical, sample: sample)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        // Resolve historical state off-main whenever the cursor/target changes (DB read).
        .task(id: historyTaskKey) { await loadHistorical() }
        // U11: resolve the selected point's culprits whenever the selection, target, or
        // viewTime changes (live = synchronous off the ring; historical = off-main DB read).
        .task(id: culpritTaskKey) { await loadCulprit() }
        // Switching target invalidates a selection from the old context AND re-scopes which
        // detail collectors run (governor stays DetailVisible across scrub — reading history is
        // independent of live collection cadence, KTD12 / U10 governor note).
        .onChange(of: target) { _, newTarget in
            selectedTime = nil; culprit = nil
            setDetailVisible(true, newTarget.visibleMetrics)
        }
        .onChange(of: viewTime) { _, _ in selectedTime = nil; culprit = nil }
        .onAppear { setDetailVisible(true, target.visibleMetrics) }
        .onDisappear { setDetailVisible(false, []) }
    }

    /// Re-runs the historical `.task` when the cursor date or target changes. `.live` keys to a
    /// stable sentinel so the task doesn't churn while live.
    private var historyTaskKey: String {
        switch viewTime {
        case .live: return "live"
        case .at(let date): return "\(target.rawValue):\(Int(date.timeIntervalSince1970))"
        }
    }

    /// Re-runs the culprit `.task` when the selected point, target, or timebase changes. A nil
    /// selection keys to a stable sentinel so the task clears (and doesn't churn).
    private var culpritTaskKey: String {
        let base: String
        switch viewTime {
        case .live: base = "live"
        case .at(let date): base = "at:\(Int(date.timeIntervalSince1970))"
        }
        let sel = selectedTime.map { Int($0.timeIntervalSince1970) }.map(String.init) ?? "none"
        return "\(target.rawValue):\(base):\(sel)"
    }

    /// Resolve the `.at` window on a background read; no-op (and clears state) while `.live`.
    private func loadHistorical() async {
        guard case .at(let date) = viewTime, let dbPool else { historical = nil; return }
        let target = self.target
        let resolved = await Task.detached(priority: .userInitiated) { () -> HistoricalResolver.Resolution? in
            try? HistoricalResolver.resolve(date: date, target: target,
                                            query: HistoryQuery(dbPool: dbPool))
        }.value
        // Only apply if still on the same cursor (avoid a stale write after another drag).
        if case .at(let current) = viewTime, Int(current.timeIntervalSince1970) == Int(date.timeIntervalSince1970) {
            historical = resolved
            if let start = resolved?.frame.windowStart { scrollPosition = start }
        }
    }

    /// Resolve the culprits for the current selection. `.live` reads the ring synchronously (no
    /// DB); `.at` reads the per-process side table off-main on the reader pool. Clears when
    /// nothing is selected. Subsystem follows the clicked graph's target (KTD7).
    private func loadCulprit() async {
        guard let selected = selectedTime else { culprit = nil; return }
        let ts = Int(selected.timeIntervalSince1970)
        let subsystem = target.subsystem
        switch viewTime {
        case .live:
            // Synchronous off the ring (KTD12 — the live path never touches the DB).
            let samples = live.ring.recent(300)
            culprit = CulpritResolver.live(samples: samples, selectedTs: ts, subsystem: subsystem)
        case .at:
            guard let dbPool else { culprit = .noData; return }
            let resolved = await Task.detached(priority: .userInitiated) { () -> CulpritResult in
                (try? CulpritResolver.historical(
                    query: HistoryQuery(dbPool: dbPool), selectedTs: ts, subsystem: subsystem))
                    ?? .noData
            }.value
            // Apply only if the selection is still the same (avoid a stale write after a re-pick).
            if let current = selectedTime, Int(current.timeIntervalSince1970) == ts {
                culprit = resolved
            }
        }
    }

    /// The detail block. When a graph point is selected (U11), the culprit list for that moment
    /// replaces the scalar detail (R9 causal drill-down — the flagship "what pegged it" answer).
    /// Otherwise it falls back to the live sample (`.live`) or recorded reading (`.at`, with the
    /// "device was asleep" gap state, OQ5).
    @ViewBuilder
    private func detailBody(isHistorical: Bool, sample: Sample?) -> some View {
        if let selected = selectedTime, let result = culprit {
            CulpritView(result: result, target: target, selected: selected)
        } else if isHistorical {
            if historical?.cursorInGap == true {
                Text("No data — device was asleep")
                    .font(.callout).foregroundStyle(.secondary)
            } else if let h = historical {
                HistoricalDetail(target: target, resolution: h)
            } else {
                CollectingRow()
            }
        } else {
            DrillDetail(target: target, sample: sample, capability: sensorCapability)
        }
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

// MARK: - Historical (scrubbed) detail

/// The recorded reading at the scrub cursor, labeled as a bucket aggregate with MAX alongside
/// AVG (KTD12 dual-path — a live spike isn't lost to averaging when scrubbed). Per-process
/// culprit attribution at the cursor is U11's job (chartXSelection); this shows the scalar.
private struct HistoricalDetail: View {
    let target: DrillTarget
    let resolution: HistoricalResolver.Resolution

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let v = resolution.cursorValue {
                Text("\(target.title) (recorded)").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    label("avg", target.unit.string(v))
                    if let mx = resolution.cursorValueMax {
                        label("max", target.unit.string(mx))
                    }
                }
                Text("Bucket aggregate — live shows raw per-tick values.")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                Text("No recorded value at this moment.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func label(_ name: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(name).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit())
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
