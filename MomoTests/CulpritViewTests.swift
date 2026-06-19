//
//  CulpritViewTests.swift
//  U11 causal drill-down (R9 / AE2). The point selection itself is a manual chart gesture; what
//  is unit-testable is the resolution behind it — `CulpritResolver`. These tests assert that a
//  selected moment surfaces the process(es) RECORDED at that moment, ranked within the clicked
//  graph's subsystem (KTD7), by `value_max` (the spike-oriented default, KTD4a), and that the
//  four degraded states (1h names dropped / no-attribution subsystem / restricted / no-data)
//  show concrete state rather than blank or fabricated names.
//
import XCTest
import GRDB
@testable import Momo

final class CulpritViewTests: XCTestCase {

    // MARK: - Fixtures

    private final class MonoCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 0
        func next() -> UInt64 { lock.lock(); defer { lock.unlock() }; value += 1_000_000_000; return value }
    }

    private func makeStore() throws -> RecordingStore {
        let counter = MonoCounter()
        return try RecordingStore.temporary(monoClock: { counter.next() })
    }

    private func cleanup(_ store: RecordingStore) {
        let path = store.dbPool.path
        for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) }
    }

    private func procRow(ts: Int, _ subsystem: Subsystem, pid: Int64, _ name: String,
                         value: Double, valueMax: Double) -> ProcRow {
        ProcRow(ts: ts, subsystem: subsystem.rawValue, pid: pid, name: name,
                value: value, valueMax: valueMax)
    }

    private func write(_ rows: [ProcRow], into tier: Tier, _ store: RecordingStore) throws {
        try store.dbPool.write { db in
            for r in rows { try RowStore.upsert(r, into: tier.procTable!, db) }
        }
    }

    private func writeScalar(_ rows: [ScalarRow], into tier: Tier, _ store: RecordingStore) throws {
        try store.dbPool.write { db in
            for r in rows { try RowStore.upsert(r, into: tier.table, db) }
        }
    }

    private func liveSample(ts: Int, _ subsystem: Subsystem,
                            _ procs: [ProcessAttribution]) -> Sample {
        Sample(timestamp: Date(timeIntervalSince1970: Double(ts)),
               cpu: CPUSample(overall: 0.5, perCore: [0.5]),
               attribution: AttributionSample(bySubsystem: [subsystem: procs]))
    }

    private func attr(_ pid: Int32, _ name: String, _ subsystem: Subsystem,
                      value: Double, restricted: Bool = false) -> ProcessAttribution {
        ProcessAttribution(pid: pid, name: name, subsystem: subsystem, value: value, restricted: restricted)
    }

    // MARK: - AE2: historical CPU spike names the recorded responsible process(es)

    /// A recorded 1m proc bucket for a CPU spike minute. Selecting that ts must name the
    /// processes recorded then, ranked by value_max — asserted against the inserted rows.
    func testAE2HistoricalCPUSpikeNamesRecordedCulprits() throws {
        let store = try makeStore(); defer { cleanup(store) }
        // "now" is 5 days out so the selection (~3 days back) is past the 48h 1s horizon and
        // resolves to the 1m tier where names are still retained (KTD4).
        let now = 5 * 86_400
        let spikeMinute = bucketStart(now - 3 * 86_400, bucketSeconds: Tier.m1.bucketSeconds)
        // Three CPU processes recorded for that minute; ffmpeg has the highest peak.
        let rows = [
            procRow(ts: spikeMinute, .cpu, pid: 101, "ffmpeg",  value: 0.40, valueMax: 0.95),
            procRow(ts: spikeMinute, .cpu, pid: 202, "Xcode",   value: 0.55, valueMax: 0.70),
            procRow(ts: spikeMinute, .cpu, pid: 303, "Spotlight", value: 0.05, valueMax: 0.30),
        ]
        try write(rows, into: .m1, store)

        let query = HistoryQuery(dbPool: store.dbPool)
        // Select mid-minute (spikeMinute + 17s) — must resolve to the bucket.
        let result = try CulpritResolver.historical(
            query: query, selectedTs: spikeMinute + 17, subsystem: .cpu, now: now)

        guard case .ranked(let subsystem, let culprits) = result else {
            return XCTFail("expected ranked culprits, got \(result)")
        }
        XCTAssertEqual(subsystem, .cpu, "subsystem follows the clicked graph (KTD7)")
        XCTAssertEqual(culprits.count, 3)
        // Ranked by value_max (spike): ffmpeg (0.95) > Xcode (0.70) > Spotlight (0.30).
        XCTAssertEqual(culprits.map(\.name), ["ffmpeg", "Xcode", "Spotlight"])
        // The named culprit and its values match what was recorded.
        XCTAssertEqual(culprits[0].valueMax, 0.95, accuracy: 1e-9)
        XCTAssertEqual(culprits[0].value, 0.40, accuracy: 1e-9)
        // Both avg and peak are surfaced so sustained-vs-spike is visible (KTD4a).
        XCTAssertNotEqual(culprits[0].value, culprits[0].valueMax)
    }

    // MARK: - Subsystem follows the clicked graph (KTD7)

    func testSubsystemFollowsClickedGraph() throws {
        let store = try makeStore(); defer { cleanup(store) }
        let now = 5 * 86_400                         // selection 3 days back → 1m tier
        let bucket = bucketStart(now - 3 * 86_400, bucketSeconds: Tier.m1.bucketSeconds)
        try write([
            procRow(ts: bucket, .cpu,  pid: 1, "cpuHog",  value: 0.3, valueMax: 0.9),
            procRow(ts: bucket, .disk, pid: 2, "diskHog", value: 100, valueMax: 5000),
            procRow(ts: bucket, .disk, pid: 3, "backupd", value: 50,  valueMax: 1000),
        ], into: .m1, store)

        let query = HistoryQuery(dbPool: store.dbPool)

        let cpu = try CulpritResolver.historical(query: query, selectedTs: bucket, subsystem: .cpu, now: now)
        guard case .ranked(.cpu, let cpuRows) = cpu else { return XCTFail("expected cpu ranked") }
        XCTAssertEqual(cpuRows.map(\.name), ["cpuHog"], "disk rows must not leak into the CPU list")

        let disk = try CulpritResolver.historical(query: query, selectedTs: bucket, subsystem: .disk, now: now)
        guard case .ranked(.disk, let diskRows) = disk else { return XCTFail("expected disk ranked") }
        XCTAssertEqual(diskRows.map(\.name), ["diskHog", "backupd"], "ranked by value_max")
    }

    // MARK: - Edge: 1h tier (names dropped) shows the aggregate + "not retained" (OQ7)

    func testOneHourTierReturnsNamesNotRetainedWithScalar() throws {
        let store = try makeStore(); defer { cleanup(store) }
        // "now" is ~60 days out so a selection ~45 days back lands on the 1h tier (1m retains 30d).
        let now = 60 * 86_400
        let selectedTs = now - 45 * 86_400
        let bucket = bucketStart(selectedTs, bucketSeconds: Tier.h1.bucketSeconds)
        var scalar = ScalarRow(ts: bucket); scalar.cpuAvg = 0.42; scalar.cpuMax = 0.88
        try writeScalar([scalar], into: .h1, store)

        let query = HistoryQuery(dbPool: store.dbPool)
        let result = try CulpritResolver.historical(
            query: query, selectedTs: selectedTs, subsystem: .cpu, now: now)

        guard case .namesNotRetained(let avg, let max) = result else {
            return XCTFail("expected namesNotRetained at the 1h tier, got \(result)")
        }
        // Never blank — the scalar AVG/MAX is still available (OQ7).
        XCTAssertEqual(try XCTUnwrap(avg), 0.42, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(max), 0.88, accuracy: 1e-9)
    }

    // MARK: - Edge: restricted (EPERM) process surfaces as restricted, not omitted (live)

    func testRestrictedProcessSurfacesNotOmitted() {
        // A live CPU selection where the top process is restricted (root/EPERM).
        let samples = [liveSample(ts: 100, .cpu, [
            attr(1, "kernel_task", .cpu, value: 0.80, restricted: true),
            attr(2, "WindowServer", .cpu, value: 0.20, restricted: false),
        ])]

        let result = CulpritResolver.live(samples: samples, selectedTs: 100, subsystem: .cpu)
        guard case .ranked(.cpu, let culprits) = result else {
            return XCTFail("expected ranked culprits, got \(result)")
        }
        XCTAssertEqual(culprits.count, 2, "the restricted process is NOT dropped")
        // It ranks first by value_max (0.80) and is flagged restricted.
        XCTAssertEqual(culprits[0].name, "kernel_task")
        XCTAssertTrue(culprits[0].restricted, "the spike's cause is surfaced, not silently hidden")
    }

    // MARK: - Edge: no-attribution subsystem (network/sensors per KTD6) is explicit, not blank

    func testNoAttributionSubsystemIsExplicit() throws {
        let store = try makeStore(); defer { cleanup(store) }
        let query = HistoryQuery(dbPool: store.dbPool)
        // network/sensors map to a nil subsystem on DrillTarget.
        let net = try CulpritResolver.historical(query: query, selectedTs: 0, subsystem: nil, now: 100)
        XCTAssertEqual(net, .noAttribution)

        let live = CulpritResolver.live(samples: [], selectedTs: 0, subsystem: nil)
        XCTAssertEqual(live, .noAttribution)

        // DrillTarget mapping is the source of truth for "which subsystem follows this graph".
        XCTAssertNil(DrillTarget.network.subsystem)
        XCTAssertNil(DrillTarget.sensors.subsystem)
        XCTAssertEqual(DrillTarget.cpu.subsystem, .cpu)
        XCTAssertEqual(DrillTarget.disk.subsystem, .disk)
    }

    // MARK: - Live happy path: nearest ring sample resolves the subsystem's processes

    func testLiveSelectionResolvesNearestSample() {
        let samples = [
            liveSample(ts: 10, .disk, [attr(1, "old", .disk, value: 10)]),
            liveSample(ts: 20, .disk, [attr(2, "torrent", .disk, value: 9000),
                                       attr(3, "Finder", .disk, value: 100)]),
            liveSample(ts: 30, .disk, [attr(4, "newer", .disk, value: 5)]),
        ]
        // Selecting near ts 21 must pick the ts-20 sample (nearest), not 10 or 30.
        let result = CulpritResolver.live(samples: samples, selectedTs: 21, subsystem: .disk)
        guard case .ranked(.disk, let culprits) = result else {
            return XCTFail("expected ranked, got \(result)")
        }
        XCTAssertEqual(culprits.map(\.name), ["torrent", "Finder"])
        // Live value_max == value (a single tick has no separate peak, KTD4a).
        XCTAssertEqual(culprits[0].value, culprits[0].valueMax)
    }

    // MARK: - noData: a selected moment with no recorded attribution

    func testNoDataWhenNoRowsAtMoment() throws {
        let store = try makeStore(); defer { cleanup(store) }
        // A recent 1s proc row at second 0 only; select second 5 (a different 1s bucket, also
        // within the 1s horizon) → no recorded row there → no data, not fabricated names.
        try write([procRow(ts: 0, .cpu, pid: 1, "a", value: 0.1, valueMax: 0.2)], into: .s1, store)
        let query = HistoryQuery(dbPool: store.dbPool)
        let result = try CulpritResolver.historical(
            query: query, selectedTs: 5, subsystem: .cpu, now: 60 * 60)
        XCTAssertEqual(result, .noData)

        // Live: empty ring → no data.
        XCTAssertEqual(CulpritResolver.live(samples: [], selectedTs: 0, subsystem: .cpu), .noData)
    }

    // MARK: - Integration: recorded via receive()+rollup, then resolved at the 1m tier (AE2 e2e)

    /// Drives the real ingest/rollup cascade (not direct row writes) so the "as recorded"
    /// guarantee holds end-to-end: a CPU spike attributed to one process at second 30 of a
    /// minute, rolled up to 1m, must be the named culprit when that minute is selected.
    func testIngestedAttributionIsResolvable() throws {
        let store = try makeStore(); defer { cleanup(store) }
        for i in 0..<60 {
            // "compiler" pegs CPU at second 30; otherwise a light background process dominates.
            let procs: [ProcessAttribution] = i == 30
                ? [attr(900, "compiler", .cpu, value: 0.97), attr(5, "idle", .cpu, value: 0.02)]
                : [attr(5, "idle", .cpu, value: 0.05)]
            store.receive(Sample(timestamp: Date(timeIntervalSince1970: Double(i)),
                                 cpu: CPUSample(overall: 0.1, perCore: [0.1]),
                                 attribution: AttributionSample(bySubsystem: [.cpu: procs])))
        }
        store.receive(Sample(timestamp: Date(timeIntervalSince1970: 60),
                             cpu: CPUSample(overall: 0.1, perCore: [0.1])))   // rollover → flush+cascade
        store.flushPending()
        try store.runCatchUp(now: 120)

        let query = HistoryQuery(dbPool: store.dbPool)
        // `now` far past the 48h 1s horizon forces tier selection to the 1m tier, where the
        // full-bucket-denominator dilution (KTD4a) is visible (vs the 1s tier where a 1-tick
        // bucket has value == value_max). The proc_1m rows were written by the rollup cascade.
        let now = 5 * 86_400
        let result = try CulpritResolver.historical(
            query: query, selectedTs: 30, subsystem: .cpu, now: now)

        guard case .ranked(.cpu, let culprits) = result else {
            return XCTFail("expected ranked culprits, got \(result)")
        }
        // "compiler" must be the top culprit by value_max (its recorded spike peak ≈ 0.97).
        XCTAssertEqual(culprits.first?.name, "compiler")
        XCTAssertEqual(try XCTUnwrap(culprits.first).valueMax, 0.97, accuracy: 1e-6)
        // Its avg is diluted by the full-bucket denominator (present 1/60 ticks), below the peak.
        XCTAssertLessThan(try XCTUnwrap(culprits.first).value, try XCTUnwrap(culprits.first).valueMax)
    }
}
