//
//  Rows.swift
//  GRDB row types + pure Sample -> table translation (KTD12).
//
//  These types own the *only* knowledge of the irreversible on-disk schema (KTD2/KTD4/
//  KTD4a). Core/Sample stays layer-neutral; nothing here leaks back up into the live path.
//  All bucketing/aggregation is expressed as PURE functions so the correctness-critical
//  math is unit-testable against plain values with no database (per the U6 execution note).
//
//  Time base (KTD2): `ts` is UTC epoch seconds = Int(timestamp.timeIntervalSince1970).
//  Aligned bucket starts: bucketStart(s) = s - s % bucketSeconds.
//
import Foundation
import GRDB

// MARK: - Tier definition (MacSlowCooker HistoryGranularity)

/// One physical resolution: bucket width, retention window, and the next coarser tier
/// it rolls up into (KTD4). 1s -> 1m -> 1h -> nil.
enum Tier: CaseIterable {
    case s1, m1, h1

    /// Bucket width in seconds. All bucketing/retention math is in UTC seconds (KTD2).
    var bucketSeconds: Int {
        switch self {
        case .s1: return 1
        case .m1: return 60
        case .h1: return 3600
        }
    }

    /// Retention horizon in seconds: 1s for 48h, 1m for 30d, 1h for ~2y (KTD4).
    var retentionSeconds: Int {
        switch self {
        case .s1: return 48 * 3600          // 48h
        case .m1: return 30 * 86_400        // 30d
        case .h1: return 2 * 365 * 86_400   // ~2y
        }
    }

    /// Scalar table name.
    var table: String {
        switch self {
        case .s1: return "samples_1s"
        case .m1: return "samples_1m"
        case .h1: return "samples_1h"
        }
    }

    /// Per-process side table, or nil at 1h where names are dropped (KTD4).
    var procTable: String? {
        switch self {
        case .s1: return "proc_1s"
        case .m1: return "proc_1m"
        case .h1: return nil
        }
    }

    /// The next coarser tier this rolls up into (KTD4 cascade).
    var nextCoarser: Tier? {
        switch self {
        case .s1: return .m1
        case .m1: return .h1
        case .h1: return nil
        }
    }
}

/// Aligned bucket start for an epoch second within a tier (pure — KTD2).
/// Uses floored division so it is correct for negative epoch seconds too.
func bucketStart(_ epochSeconds: Int, bucketSeconds: Int) -> Int {
    let r = epochSeconds % bucketSeconds
    return r >= 0 ? epochSeconds - r : epochSeconds - r - bucketSeconds
}

// MARK: - Scalar metric row

/// One scalar-tier row. Every metric is independently optional (REAL NULL) so a missing
/// sensor stores NULL for its own column without poisoning other metrics' aggregates
/// (KTD4 / U6 test "missing-sensor NULL"). Gauge metrics carry both AVG and MAX so the
/// 1h tier doesn't hide spikes (KTD4 / RRDtool AVG+MAX). `fgApp` is dropped at 1h (KTD4).
struct ScalarRow: Equatable {
    var ts: Int

    var cpuAvg: Double?
    var cpuMax: Double?

    var memUsedAvg: Double?
    var memUsedMax: Double?
    var memTotal: Double?        // capacity — slowly changing, single value
    var memPressureMax: Double?  // peak pressure (raw enum value) in the bucket
    var swapUsedAvg: Double?
    var swapUsedMax: Double?

    var diskFree: Double?        // capacity — single value
    var diskTotal: Double?
    var diskReadAvg: Double?
    var diskReadMax: Double?
    var diskWriteAvg: Double?
    var diskWriteMax: Double?

    var netRxAvg: Double?
    var netRxMax: Double?
    var netTxAvg: Double?
    var netTxMax: Double?

    var tempMaxAvg: Double?      // hottest sensor: avg-of-max and peak-of-max
    var tempMaxMax: Double?
    var fanMaxAvg: Double?
    var fanMaxMax: Double?
    var thermalMax: Double?      // peak thermal state (raw enum value)

    var fgApp: String?           // foreground app — dropped at the 1h tier (KTD4)

    /// Count of attribution samples that contributed to this bucket (KTD3 sub-cadence).
    /// This is the per-process `value` denominator (not the scalar tick count), because
    /// attribution is sampled on a slower sub-cadence than scalar metrics. A coarser tier's
    /// `procN` is the SUM of its finer rows' `procN` (total attribution samples in the window).
    var procN: Int = 0
}

/// One per-process attribution row, keyed by (ts, subsystem, pid) — KTD4a. `value` is the
/// full-bucket-denominator average; `valueMax` is the per-process peak (irreversible — it
/// cannot be backfilled once raw ticks are pruned). No row exists at the 1h tier.
struct ProcRow: Equatable {
    var ts: Int
    var subsystem: String
    var pid: Int64
    var name: String
    var value: Double
    var valueMax: Double
}

// MARK: - Per-tick projection (Sample -> finest-tier observation)

/// One tick's scalar observation, projected from a Sample. `nil` means "metric absent this
/// tick"; it never contributes to that column's aggregate (vs. a present 0 which does).
struct ScalarObservation {
    var cpu: Double?
    var memUsed: Double?
    var memTotal: Double?
    var memPressure: Double?
    var swapUsed: Double?
    var diskFree: Double?
    var diskTotal: Double?
    var diskRead: Double?
    var diskWrite: Double?
    var netRx: Double?
    var netTx: Double?
    var temp: Double?       // hottest temperature this tick
    var fan: Double?        // fastest fan this tick
    var thermal: Double?
    var fgApp: String?

    /// Whether this tick carried per-process attribution (KTD3 sub-cadence). Attribution
    /// runs every Nth tick, so this is true on only ~1/N of the ticks in a bucket; counting
    /// the true ones gives the per-process `value` denominator (vs. the full tick count).
    var hasAttribution: Bool = false

    init(_ sample: Sample) {
        hasAttribution = (sample.attribution != nil)
        cpu = sample.cpu?.overall
        if let m = sample.memory {
            memUsed = Double(m.usedBytes)
            memTotal = Double(m.totalBytes)
            memPressure = Double(m.pressure.rawValue)
            swapUsed = Double(m.swapUsedBytes)
        }
        if let d = sample.disk {
            diskFree = Double(d.freeBytes)
            diskTotal = Double(d.totalBytes)
            diskRead = d.readBytesPerSec
            diskWrite = d.writeBytesPerSec
        }
        if let n = sample.network {
            netRx = n.rxBytesPerSec
            netTx = n.txBytesPerSec
        }
        if let s = sample.sensors {
            temp = s.temperatures.map(\.celsius).max()
            fan = s.fans.map(\.rpm).max()
            thermal = Double(s.thermalState.rawValue)
        }
        fgApp = sample.context.foregroundApp
    }
}

/// One tick's per-process observation: (subsystem, pid, name) -> per-tick value (KTD4a).
struct ProcObservation: Equatable {
    var subsystem: String
    var pid: Int64
    var name: String
    var value: Double
}

extension ProcObservation {
    /// Project a Sample's top-N attribution into flat per-tick rows.
    static func from(_ sample: Sample) -> [ProcObservation] {
        guard let attribution = sample.attribution else { return [] }
        var out: [ProcObservation] = []
        for (subsystem, rows) in attribution.bySubsystem {
            for r in rows {
                out.append(ProcObservation(
                    subsystem: subsystem.rawValue,
                    pid: Int64(r.pid),
                    name: r.name,
                    value: r.value
                ))
            }
        }
        return out
    }
}

// MARK: - Pure scalar aggregation (RRDtool AVG/MAX, nil-compacting)

/// AVG/MAX over the non-nil values; nil when every input was absent (KTD4 nil-compaction).
private func aggregate(_ values: [Double?]) -> (avg: Double?, max: Double?) {
    let present = values.compactMap { $0 }
    guard !present.isEmpty else { return (nil, nil) }
    let sum = present.reduce(0, +)
    return (sum / Double(present.count), present.max())
}

private func peak(_ values: [Double?]) -> Double? {
    values.compactMap { $0 }.max()
}

private func lastNonNil(_ values: [Double?]) -> Double? {
    values.last(where: { $0 != nil }) ?? nil
}

private func lastNonNilString(_ values: [String?]) -> String? {
    values.last(where: { $0 != nil }) ?? nil
}

/// Fold a bucket's worth of scalar observations into one ScalarRow (pure — KTD4).
/// `bucketTs` is the aligned bucket start. Capacity metrics (mem/disk total, free) carry
/// the last present value forward; gauges store AVG+MAX; enums store the peak.
func aggregateScalars(ts bucketTs: Int, _ obs: [ScalarObservation]) -> ScalarRow {
    let cpu = aggregate(obs.map(\.cpu))
    let memUsed = aggregate(obs.map(\.memUsed))
    let swap = aggregate(obs.map(\.swapUsed))
    let diskRead = aggregate(obs.map(\.diskRead))
    let diskWrite = aggregate(obs.map(\.diskWrite))
    let netRx = aggregate(obs.map(\.netRx))
    let netTx = aggregate(obs.map(\.netTx))
    let temp = aggregate(obs.map(\.temp))
    let fan = aggregate(obs.map(\.fan))

    return ScalarRow(
        ts: bucketTs,
        cpuAvg: cpu.avg, cpuMax: cpu.max,
        memUsedAvg: memUsed.avg, memUsedMax: memUsed.max,
        memTotal: lastNonNil(obs.map(\.memTotal)),
        memPressureMax: peak(obs.map(\.memPressure)),
        swapUsedAvg: swap.avg, swapUsedMax: swap.max,
        diskFree: lastNonNil(obs.map(\.diskFree)),
        diskTotal: lastNonNil(obs.map(\.diskTotal)),
        diskReadAvg: diskRead.avg, diskReadMax: diskRead.max,
        diskWriteAvg: diskWrite.avg, diskWriteMax: diskWrite.max,
        netRxAvg: netRx.avg, netRxMax: netRx.max,
        netTxAvg: netTx.avg, netTxMax: netTx.max,
        tempMaxAvg: temp.avg, tempMaxMax: temp.max,
        fanMaxAvg: fan.avg, fanMaxMax: fan.max,
        thermalMax: peak(obs.map(\.thermal)),
        fgApp: lastNonNilString(obs.map(\.fgApp)),
        procN: obs.filter(\.hasAttribution).count
    )
}

/// Roll coarser-tier scalars from a set of sealed finer-tier ScalarRows (pure — KTD4).
/// AVG-of-coarser = unweighted mean of the finer AVGs present; MAX = max of finer MAXes.
/// (Finer buckets within a coarser window are equal-width, so an unweighted mean of the
/// finer AVGs equals the tick-weighted mean to within rounding for full buckets.)
/// `dropNames` is informational here; name-dropping happens by not writing proc rows.
func rollupScalars(ts bucketTs: Int, _ finer: [ScalarRow], dropForeground: Bool) -> ScalarRow {
    func avgOf(_ kp: KeyPath<ScalarRow, Double?>) -> Double? {
        aggregate(finer.map { $0[keyPath: kp] }).avg
    }
    func maxOf(_ kp: KeyPath<ScalarRow, Double?>) -> Double? {
        peak(finer.map { $0[keyPath: kp] })
    }
    return ScalarRow(
        ts: bucketTs,
        cpuAvg: avgOf(\.cpuAvg), cpuMax: maxOf(\.cpuMax),
        memUsedAvg: avgOf(\.memUsedAvg), memUsedMax: maxOf(\.memUsedMax),
        memTotal: finer.compactMap(\.memTotal).last,
        memPressureMax: maxOf(\.memPressureMax),
        swapUsedAvg: avgOf(\.swapUsedAvg), swapUsedMax: maxOf(\.swapUsedMax),
        diskFree: finer.compactMap(\.diskFree).last,
        diskTotal: finer.compactMap(\.diskTotal).last,
        diskReadAvg: avgOf(\.diskReadAvg), diskReadMax: maxOf(\.diskReadMax),
        diskWriteAvg: avgOf(\.diskWriteAvg), diskWriteMax: maxOf(\.diskWriteMax),
        netRxAvg: avgOf(\.netRxAvg), netRxMax: maxOf(\.netRxMax),
        netTxAvg: avgOf(\.netTxAvg), netTxMax: maxOf(\.netTxMax),
        tempMaxAvg: avgOf(\.tempMaxAvg), tempMaxMax: maxOf(\.tempMaxMax),
        fanMaxAvg: avgOf(\.fanMaxAvg), fanMaxMax: maxOf(\.fanMaxMax),
        thermalMax: maxOf(\.thermalMax),
        fgApp: dropForeground ? nil : finer.compactMap(\.fgApp).last,
        // Total attribution samples across the window = the coarse per-process denominator.
        procN: finer.reduce(0) { $0 + $1.procN }
    )
}

// MARK: - Pure per-process aggregation (KTD4a)

/// Survivor cap factor: union of top-N by value_max AND top-N by value, deduped, bounded
/// to ~2N (KTD4a).
let perBucketTopN = 5

/// Aggregate one bucket's per-tick per-process observations into per-bucket rows (KTD4a).
///
/// - `attributionSampleCount` is the number of ticks in the bucket where attribution was
///   actually sampled (KTD3 sub-cadence) — the per-process `value` denominator. Ticks where
///   a process was absent from top-N (but attribution ran) count as 0, so a brief spike does
///   not inflate `value`; a process present in every attribution sample reports its true
///   value, undeflated by the sub-cadence factor.
/// - A `(pid, name)` change within the bucket is TWO distinct keys, never summed.
/// - `value` = sum(per-tick values) / attributionSampleCount; `valueMax` = per-process peak.
/// - Survivors per subsystem = union of top-N by `valueMax` and top-N by `value`, deduped,
///   bounded to ~2N, ties broken by `valueMax`.
func aggregateProcs(
    ts bucketTs: Int,
    attributionSampleCount: Int,
    _ obs: [ProcObservation],
    topN: Int = perBucketTopN
) -> [ProcRow] {
    let denominator = Swift.max(attributionSampleCount, 1)

    struct Key: Hashable { let subsystem: String; let pid: Int64; let name: String }
    var sums: [Key: Double] = [:]
    var peaks: [Key: Double] = [:]
    for o in obs {
        let k = Key(subsystem: o.subsystem, pid: o.pid, name: o.name)
        sums[k, default: 0] += o.value
        peaks[k] = Swift.max(peaks[k] ?? -.infinity, o.value)
    }

    // Build candidate rows, grouped by subsystem.
    var bySubsystem: [String: [ProcRow]] = [:]
    for (k, sum) in sums {
        let row = ProcRow(
            ts: bucketTs,
            subsystem: k.subsystem,
            pid: k.pid,
            name: k.name,
            value: sum / Double(denominator),
            valueMax: peaks[k] ?? 0
        )
        bySubsystem[k.subsystem, default: []].append(row)
    }

    // Survivor selection per subsystem: union of top-N by valueMax and top-N by value.
    var out: [ProcRow] = []
    for (_, rows) in bySubsystem {
        out.append(contentsOf: selectSurvivors(rows, topN: topN))
    }
    return out
}

/// Union of top-N by `valueMax` and top-N by `value`, deduped on (pid,name), ties broken
/// by `valueMax` (KTD4a). Pure, so it is testable without a DB.
func selectSurvivors(_ rows: [ProcRow], topN: Int) -> [ProcRow] {
    func order(_ a: ProcRow, _ b: ProcRow, by primary: KeyPath<ProcRow, Double>) -> Bool {
        let pa = a[keyPath: primary], pb = b[keyPath: primary]
        if pa != pb { return pa > pb }
        if a.valueMax != b.valueMax { return a.valueMax > b.valueMax }
        if a.value != b.value { return a.value > b.value }
        // Stable, deterministic final tiebreak so the survivor set is reproducible.
        if a.pid != b.pid { return a.pid < b.pid }
        return a.name < b.name
    }
    let byMax = Array(rows.sorted { order($0, $1, by: \.valueMax) }.prefix(topN))
    let byAvg = Array(rows.sorted { order($0, $1, by: \.value) }.prefix(topN))

    var seen = Set<String>()
    var union: [ProcRow] = []
    for r in byMax + byAvg {
        let id = "\(r.pid):\(r.name)"
        if seen.insert(id).inserted { union.append(r) }
    }
    return union
}

// MARK: - GRDB persistence (the only place these rows touch SQL)

private let scalarColumns = [
    "ts", "cpu_avg", "cpu_max",
    "mem_used_avg", "mem_used_max", "mem_total", "mem_pressure_max",
    "swap_used_avg", "swap_used_max",
    "disk_free", "disk_total", "disk_read_avg", "disk_read_max",
    "disk_write_avg", "disk_write_max",
    "net_rx_avg", "net_rx_max", "net_tx_avg", "net_tx_max",
    "temp_max_avg", "temp_max_max", "fan_max_avg", "fan_max_max",
    "thermal_max", "fg_app", "proc_n",
]

extension ScalarRow {
    var arguments: StatementArguments {
        [
            ts, cpuAvg, cpuMax,
            memUsedAvg, memUsedMax, memTotal, memPressureMax,
            swapUsedAvg, swapUsedMax,
            diskFree, diskTotal, diskReadAvg, diskReadMax,
            diskWriteAvg, diskWriteMax,
            netRxAvg, netRxMax, netTxAvg, netTxMax,
            tempMaxAvg, tempMaxMax, fanMaxAvg, fanMaxMax,
            thermalMax, fgApp, procN,
        ]
    }

    init(row: Row) {
        ts = row["ts"]
        cpuAvg = row["cpu_avg"]; cpuMax = row["cpu_max"]
        memUsedAvg = row["mem_used_avg"]; memUsedMax = row["mem_used_max"]
        memTotal = row["mem_total"]; memPressureMax = row["mem_pressure_max"]
        swapUsedAvg = row["swap_used_avg"]; swapUsedMax = row["swap_used_max"]
        diskFree = row["disk_free"]; diskTotal = row["disk_total"]
        diskReadAvg = row["disk_read_avg"]; diskReadMax = row["disk_read_max"]
        diskWriteAvg = row["disk_write_avg"]; diskWriteMax = row["disk_write_max"]
        netRxAvg = row["net_rx_avg"]; netRxMax = row["net_rx_max"]
        netTxAvg = row["net_tx_avg"]; netTxMax = row["net_tx_max"]
        tempMaxAvg = row["temp_max_avg"]; tempMaxMax = row["temp_max_max"]
        fanMaxAvg = row["fan_max_avg"]; fanMaxMax = row["fan_max_max"]
        thermalMax = row["thermal_max"]; fgApp = row["fg_app"]
        procN = row["proc_n"] ?? 0
    }
}

extension ProcRow {
    init(row: Row) {
        ts = row["ts"]; subsystem = row["subsystem"]; pid = row["pid"]
        name = row["name"]; value = row["value"]; valueMax = row["value_max"]
    }
}

/// All SQL for the tier tables lives here so the schema stays encapsulated in Store/.
enum RowStore {
    private static let scalarPlaceholders =
        scalarColumns.map { _ in "?" }.joined(separator: ", ")
    private static let scalarColumnList = scalarColumns.joined(separator: ", ")

    /// INSERT OR REPLACE one scalar row — whole-row replace (KTD2/U6 re-flush contract).
    static func upsert(_ row: ScalarRow, into table: String, _ db: Database) throws {
        try db.execute(
            sql: "INSERT OR REPLACE INTO \(table) (\(scalarColumnList)) VALUES (\(scalarPlaceholders))",
            arguments: row.arguments)
    }

    static func upsert(_ row: ProcRow, into table: String, _ db: Database) throws {
        try db.execute(sql: """
            INSERT OR REPLACE INTO \(table) (ts, subsystem, pid, name, value, value_max)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [row.ts, row.subsystem, row.pid, row.name, row.value, row.valueMax])
    }

    static func scalars(in table: String, from lo: Int, to hi: Int, _ db: Database) throws -> [ScalarRow] {
        try Row.fetchAll(db,
            sql: "SELECT * FROM \(table) WHERE ts >= ? AND ts < ? ORDER BY ts",
            arguments: [lo, hi])
            .map(ScalarRow.init(row:))
    }

    static func procs(in table: String, from lo: Int, to hi: Int, _ db: Database) throws -> [ProcRow] {
        try Row.fetchAll(db,
            sql: "SELECT * FROM \(table) WHERE ts >= ? AND ts < ? ORDER BY ts",
            arguments: [lo, hi])
            .map(ProcRow.init(row:))
    }

    /// Max ts present in a scalar table, or nil if empty.
    static func maxTs(in table: String, _ db: Database) throws -> Int? {
        try Int.fetchOne(db, sql: "SELECT MAX(ts) FROM \(table)")
    }

    static func count(in table: String, _ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
    }
}
