//
//  CulpritView.swift
//  Causal drill-down — "what pegged my CPU at 3am" (R9 / AE2 / U11).
//
//  Selecting any point on a graph (live or historical) surfaces the responsible process(es)
//  for that moment, ranked WITHIN the clicked graph's subsystem (KTD7 — no cross-subsystem
//  normalization). The selection comes from `chartXSelection` (MetricChart) as a `Date`; the
//  panel maps it to UTC epoch seconds and resolves a `CulpritResult`.
//
//  Resolution is split from the SwiftUI view so AE2 is unit-testable without UI:
//    * `CulpritResolver.live(...)`       — nearest ring `Sample` → its captured attribution.
//    * `CulpritResolver.historical(...)` — tier-select for the ts, read the per-process side
//      table (`proc_1s`/`proc_1m`); at the 1h tier (proc table dropped, KTD4) return the
//      "names not retained" state alongside the scalar AVG/MAX (OQ7) — never blank/fabricated.
//
//  Ranking (KTD4a): the causal "what pegged it" question defaults to `value_max` (the spike),
//  and BOTH `value` (avg) and `value_max` are shown so the sustained-vs-spike distinction is
//  visible. A future refinement could rank by `value` when the AVG series point was clicked
//  (the plan's "match the series clicked" nuance); v1 keeps the single spike-oriented default.
//
//  Restricted (EPERM) processes surface as "restricted" rather than being dropped, so the
//  spike's cause is never silently hidden (KTD4 / U11 EPERM edge). Restriction is a live-only
//  signal — the recorded `proc_*` schema carries no restricted flag, so historical rows are
//  always concrete names.
//
import SwiftUI
import GRDB

// MARK: - Result model (pure, testable)

/// One responsible process at the selected moment, ranked within its subsystem.
struct Culprit: Equatable, Identifiable {
    let pid: Int
    let name: String
    /// Avg contribution over the bucket (historical) or this tick (live). CPU/mem fraction,
    /// resident bytes, or disk bytes/sec by subsystem.
    let value: Double
    /// Peak contribution (`value_max`) — the spike-oriented ranking key (KTD4a). Equals
    /// `value` on the live path (a single tick has no separate peak).
    let valueMax: Double
    /// EPERM/root process that couldn't be read (live only) — surfaced, not dropped.
    let restricted: Bool

    var id: String { "\(pid):\(name)" }
}

/// The resolved culprit state for a selected point. Distinguishes the four U11 outcomes so the
/// view never shows blank or fabricated data:
///   * `.ranked`           — a per-process list (live ring or 1s/1m proc table).
///   * `.namesNotRetained` — the selected ts is at the 1h tier (names dropped, KTD4 / OQ7);
///                            the scalar AVG/MAX is still carried.
///   * `.noAttribution`    — the clicked subsystem tracks no per-process attribution
///                            (network is system-wide per KTD6; sensors have none).
///   * `.noData`           — no sample/row covers the selected moment (a gap, or pre-record).
enum CulpritResult: Equatable {
    case ranked(subsystem: Subsystem, culprits: [Culprit])
    case namesNotRetained(scalarAvg: Double?, scalarMax: Double?)
    case noAttribution
    case noData
}

// MARK: - Resolver (pure-ish: live takes samples, historical takes the reader pool)

enum CulpritResolver {

    /// How many ranked processes to surface (mirrors the recorded `perBucketTopN` survivor cap
    /// so the live and historical lists are the same length class).
    static let displayN = 5

    /// Resolve culprits for a LIVE selection. Finds the ring sample nearest `selectedTs` and
    /// reads its captured `attribution.bySubsystem[subsystem]`, ranked by per-tick value.
    ///
    /// - `samples` is the live ring window (oldest-first), e.g. `live.ring.recent(...)`.
    /// - `subsystem` is the clicked graph's subsystem (KTD7); nil → `.noAttribution`.
    static func live(samples: [Sample], selectedTs: Int, subsystem: Subsystem?) -> CulpritResult {
        guard let subsystem else { return .noAttribution }
        guard let sample = nearest(samples, to: selectedTs) else { return .noData }
        guard let rows = sample.attribution?.bySubsystem[subsystem] else {
            // The sub-cadence attribution tick hadn't run for the nearest sample — no data
            // captured for this subsystem at this moment, not an empty culprit list.
            return .noData
        }
        // Live per-tick has no separate peak; value_max == value. Rank by value (== value_max).
        let culprits = rows
            .map { Culprit(pid: Int($0.pid), name: $0.name, value: $0.value,
                           valueMax: $0.value, restricted: $0.restricted) }
            .sorted(by: ranks)
            .prefix(displayN)
        return .ranked(subsystem: subsystem, culprits: Array(culprits))
    }

    /// Resolve culprits for a HISTORICAL selection. Picks the tier for `selectedTs` (by the same
    /// budget rule the chart uses), then:
    ///   * 1s/1m → read the proc side table at the aligned bucket and rank by `value_max`.
    ///   * 1h    → proc table is nil (names dropped, KTD4) → `.namesNotRetained` with the scalar
    ///             AVG/MAX read from `samples_1h` so the view still shows the aggregate (OQ7).
    ///
    /// `now` gates tier selection by retention (an old ts can't pick a pruned-away fine tier),
    /// matching `HistoryQuery`. The read runs on the reader pool — never blocks ingest.
    static func historical(
        query: HistoryQuery,
        selectedTs: Int,
        subsystem: Subsystem?,
        now: Int = Int(Date().timeIntervalSince1970)
    ) throws -> CulpritResult {
        guard let subsystem else { return .noAttribution }

        // Select the same tier the chart would for a point query at this ts (a 1-bucket window
        // at the finest tier so a recent selection resolves to 1s, an older one to 1m/1h).
        let tier = HistoryQueryPlan.selectTier(
            start: selectedTs, end: selectedTs + 1, budget: query.budget, now: now)

        return try query.dbPool.read { db -> CulpritResult in
            guard let procTable = tier.procTable else {
                // 1h tier: names dropped (KTD4). Show the scalar aggregate, not blank (OQ7).
                let bucket = bucketStart(selectedTs, bucketSeconds: tier.bucketSeconds)
                let row = try RowStore
                    .scalars(in: tier.table, from: bucket, to: bucket + tier.bucketSeconds, db)
                    .first
                let scalar = row.flatMap { subsystem.recordedScalar($0) }
                return .namesNotRetained(scalarAvg: scalar?.avg, scalarMax: scalar?.max)
            }

            // 1s/1m tier: read the proc rows for the aligned bucket, filter to the clicked
            // subsystem, rank by value_max (KTD4a spike default), cap to displayN.
            let bucket = bucketStart(selectedTs, bucketSeconds: tier.bucketSeconds)
            let rows = try RowStore.procs(
                in: procTable, from: bucket, to: bucket + tier.bucketSeconds, db)
            let culprits = rows
                .filter { $0.subsystem == subsystem.rawValue }
                .map { Culprit(pid: Int($0.pid), name: $0.name, value: $0.value,
                               valueMax: $0.valueMax, restricted: false) }
                .sorted(by: ranks)
                .prefix(displayN)
            if culprits.isEmpty {
                // A present scalar row with no recorded survivors for this subsystem, or no row
                // at all → no attribution data for the moment (distinct from name-aged-out).
                return .noData
            }
            return .ranked(subsystem: subsystem, culprits: Array(culprits))
        }
    }

    // MARK: - Helpers

    /// Spike-oriented ranking (KTD4a): by `valueMax` desc, then `value` desc, then a stable
    /// deterministic tiebreak so the order is reproducible.
    private static func ranks(_ a: Culprit, _ b: Culprit) -> Bool {
        if a.valueMax != b.valueMax { return a.valueMax > b.valueMax }
        if a.value != b.value { return a.value > b.value }
        if a.pid != b.pid { return a.pid < b.pid }
        return a.name < b.name
    }

    /// The ring sample whose timestamp is closest to `ts` (selection lands on the nearest
    /// recorded tick). nil only when the window is empty.
    private static func nearest(_ samples: [Sample], to ts: Int) -> Sample? {
        samples.min(by: { a, b in
            abs(Int(a.timestamp.timeIntervalSince1970) - ts)
                < abs(Int(b.timestamp.timeIntervalSince1970) - ts)
        })
    }
}

// MARK: - Subsystem → recorded scalar (for the 1h "names not retained" aggregate)

private extension Subsystem {
    /// The scalar AVG/MAX this subsystem plots, read from a recorded `ScalarRow` — so the 1h
    /// state shows the aggregate alongside the "names not retained" line (OQ7). Mirrors
    /// `DrillTarget.historicalScalar` for the per-process subsystems only.
    func recordedScalar(_ r: ScalarRow) -> (avg: Double, max: Double?)? {
        switch self {
        case .cpu:
            guard let avg = r.cpuAvg else { return nil }
            return (avg, r.cpuMax)
        case .memory:
            guard let total = r.memTotal, total > 0, let used = r.memUsedAvg else { return nil }
            return (used / total, r.memUsedMax.map { $0 / total })
        case .disk:
            guard r.diskReadAvg != nil || r.diskWriteAvg != nil else { return nil }
            let avg = (r.diskReadAvg ?? 0) + (r.diskWriteAvg ?? 0)
            let mx = r.diskReadMax != nil || r.diskWriteMax != nil
                ? (r.diskReadMax ?? 0) + (r.diskWriteMax ?? 0) : nil
            return (avg, mx)
        }
    }
}

// MARK: - View

/// Renders a resolved `CulpritResult` for the selected moment. Shown in the drill-down panel
/// when a graph point is selected (replacing the scalar-only detail body). Every branch shows
/// something concrete — a ranked list, the aged-out note + aggregate, a system-wide note, or a
/// no-data note — never blank or fabricated (U11 / OQ7 / KTD6).
struct CulpritView: View {
    let result: CulpritResult
    let target: DrillTarget
    /// The selected instant, for the header ("responsible at …").
    let selected: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            content
        }
    }

    private var header: some View {
        Text("Responsible processes · \(timeString)")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var content: some View {
        switch result {
        case .ranked(_, let culprits) where culprits.isEmpty:
            Text("No significant processes at this moment.")
                .font(.caption2).foregroundStyle(.secondary)
        case .ranked(_, let culprits):
            ForEach(culprits) { c in
                HStack(spacing: 8) {
                    Text(c.restricted ? "\(c.name) (restricted)" : c.name).lineLimit(1)
                    Spacer()
                    // value_max is the spike (the "what pegged it" key); value is the avg.
                    Text(format(c.valueMax)).monospacedDigit()
                    if c.value != c.valueMax {
                        Text("avg \(format(c.value))")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }.font(.callout)
            }
        case .namesNotRetained(let avg, let max):
            // OQ7: a single explanatory line in place of the list, alongside the scalar.
            Text("Process names are not retained past 30 days")
                .font(.callout).foregroundStyle(.secondary)
            if let avg {
                HStack(spacing: 12) {
                    aggregate("avg", avg)
                    if let max { aggregate("max", max) }
                }
            }
        case .noAttribution:
            // KTD6: network is system-wide; sensors have no per-process attribution.
            Text("Per-process attribution isn't tracked for this metric.")
                .font(.callout).foregroundStyle(.secondary)
        case .noData:
            Text("No attribution recorded at this moment.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var timeString: String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f.string(from: selected)
    }

    private func aggregate(_ name: String, _ value: Double) -> some View {
        HStack(spacing: 4) {
            Text(name).font(.caption2).foregroundStyle(.secondary)
            Text(target.unit.string(value)).font(.callout.monospacedDigit())
        }
    }

    /// Format a culprit value by the subsystem's natural unit (CPU %, mem bytes, disk rate).
    private func format(_ v: Double) -> String {
        switch target.subsystem {
        case .cpu:    return MetricFormat.percent(v)
        case .memory: return MetricFormat.bytes(UInt64(max(0, v)))
        case .disk:   return MetricFormat.rate(v)
        case .none:   return target.unit.string(v)
        }
    }
}
