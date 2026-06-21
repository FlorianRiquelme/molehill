//
//  RollupTests.swift
//  Pure aggregation/bucketing + cascade/prune/catch-up correctness (KTD2/KTD4/KTD4a).
//  The pure tests need no DB; the cascade/prune tests run against a throwaway DatabasePool.
//
import XCTest
import GRDB
@testable import Momo

final class RollupTests: XCTestCase {

    // MARK: - Pure: bucketStart alignment (KTD2)

    func testBucketStartAlignsToWidth() {
        XCTAssertEqual(bucketStart(125, bucketSeconds: 60), 120)
        XCTAssertEqual(bucketStart(120, bucketSeconds: 60), 120)
        XCTAssertEqual(bucketStart(179, bucketSeconds: 60), 120)
        XCTAssertEqual(bucketStart(3661, bucketSeconds: 3600), 3600)
        XCTAssertEqual(bucketStart(59, bucketSeconds: 1), 59)
    }

    func testBucketStartHandlesNegativeEpoch() {
        // Floored division so pre-1970 ts (and DST math) bucket without drift.
        XCTAssertEqual(bucketStart(-1, bucketSeconds: 60), -60)
        XCTAssertEqual(bucketStart(-60, bucketSeconds: 60), -60)
        XCTAssertEqual(bucketStart(-61, bucketSeconds: 60), -120)
    }

    // MARK: - Pure: scalar AVG/MAX with nil-compaction (KTD4)

    func testScalarAvgMaxAcrossMinute() {
        let obs = (0..<60).map { i -> ScalarObservation in
            var o = ScalarObservation(Sample(timestamp: Date(timeIntervalSince1970: Double(i))))
            o.cpu = Double(i) / 100.0
            return o
        }
        let row = aggregateScalars(ts: 0, obs)
        XCTAssertEqual(row.cpuMax!, 0.59, accuracy: 1e-9)
        XCTAssertEqual(row.cpuAvg!, (0..<60).map { Double($0) / 100 }.reduce(0,+) / 60, accuracy: 1e-9)
    }

    func testSpikyMetricMaxPreservedWhileAvgLow() {
        var obs = (0..<60).map { _ -> ScalarObservation in
            var o = ScalarObservation(Sample(timestamp: Date(timeIntervalSince1970: 0)))
            o.cpu = 0.01
            return o
        }
        obs[30].cpu = 0.99   // single spike
        let row = aggregateScalars(ts: 0, obs)
        XCTAssertEqual(row.cpuMax!, 0.99, accuracy: 1e-9)
        XCTAssertLessThan(row.cpuAvg!, 0.05)   // avg stays low
    }

    func testMissingSensorNullDoesNotAffectOtherMetrics() {
        var obs: [ScalarObservation] = []
        for i in 0..<10 {
            var o = ScalarObservation(Sample(timestamp: Date(timeIntervalSince1970: Double(i))))
            o.cpu = 0.5
            o.temp = nil          // sensor absent every tick
            obs.append(o)
        }
        let row = aggregateScalars(ts: 0, obs)
        XCTAssertEqual(row.cpuAvg!, 0.5, accuracy: 1e-9)
        XCTAssertNil(row.tempMaxAvg)   // NULL, not zero
        XCTAssertNil(row.tempMaxMax)
    }

    func testSubCadenceMetricCompactsNilTicks() {
        // Sensors present on only 2 of 10 ticks: avg/max computed over the 2 present, not 10.
        var obs: [ScalarObservation] = []
        for i in 0..<10 {
            var o = ScalarObservation(Sample(timestamp: Date(timeIntervalSince1970: Double(i))))
            o.cpu = 0.5
            o.temp = (i == 3 || i == 7) ? 80.0 : nil
            obs.append(o)
        }
        let row = aggregateScalars(ts: 0, obs)
        XCTAssertEqual(row.tempMaxAvg!, 80.0, accuracy: 1e-9)
        XCTAssertEqual(row.tempMaxMax!, 80.0, accuracy: 1e-9)
    }

    // MARK: - Pure: per-process aggregation (KTD4a)

    func testPerProcessSampleCountDenominatorAndPeak() {
        // Denominator is the attribution-SAMPLE count (KTD3 sub-cadence), not the tick count.
        // Sustained: pid present in ALL 20 attribution samples at 0.8 -> value == 0.8.
        var sustained: [ProcObservation] = []
        for _ in 0..<20 {
            sustained.append(ProcObservation(subsystem: "cpu", pid: 42, name: "X", value: 0.8))
        }
        let sRows = aggregateProcs(ts: 0, attributionSampleCount: 20, sustained)
        let s = sRows.first { $0.pid == 42 }!
        XCTAssertEqual(s.value, 0.8, accuracy: 1e-9, "present in every sample -> true value, not deflated")
        XCTAssertEqual(s.valueMax, 0.8, accuracy: 1e-9)

        // Partial: present in 10 of 20 attribution samples at 0.8 -> diluted across the SAMPLE
        // count (not the tick count): 0.8 * 10 / 20 == 0.4.
        var partial: [ProcObservation] = []
        for _ in 0..<10 {
            partial.append(ProcObservation(subsystem: "cpu", pid: 7, name: "Y", value: 0.8))
        }
        let pRows = aggregateProcs(ts: 0, attributionSampleCount: 20, partial)
        let p = pRows.first { $0.pid == 7 }!
        XCTAssertEqual(p.value, 0.8 * 10 / 20, accuracy: 1e-9)
        XCTAssertEqual(p.valueMax, 0.8, accuracy: 1e-9)
    }

    func testPidReuseProducesTwoDistinctRows() {
        // Same pid, two different names within the bucket = two rows, never summed.
        let obs = [
            ProcObservation(subsystem: "cpu", pid: 7, name: "Old", value: 0.4),
            ProcObservation(subsystem: "cpu", pid: 7, name: "New", value: 0.5),
        ]
        let rows = aggregateProcs(ts: 0, attributionSampleCount: 1, obs).filter { $0.pid == 7 }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.name)), ["Old", "New"])
    }

    func testTopNSurvivorUnionOfMaxAndAvg() {
        // Build > 2N candidates: one sustained (high avg, modest peak), one spiky (low avg,
        // high peak). Both must survive the union even at small N.
        var obs: [ProcObservation] = []
        // sustained pid 1: 0.7 every tick (high avg)
        for _ in 0..<10 { obs.append(ProcObservation(subsystem: "cpu", pid: 1, name: "Sustained", value: 0.7)) }
        // spiky pid 2: one 0.95 tick (high peak, low avg)
        obs.append(ProcObservation(subsystem: "cpu", pid: 2, name: "Spiky", value: 0.95))
        // filler pids with middling values
        for p in 3...10 { obs.append(ProcObservation(subsystem: "cpu", pid: Int64(p), name: "F\(p)", value: 0.3)) }

        let rows = aggregateProcs(ts: 0, attributionSampleCount: 10, obs, topN: 2)
        let names = Set(rows.map(\.name))
        XCTAssertTrue(names.contains("Sustained"), "top-by-value must survive")
        XCTAssertTrue(names.contains("Spiky"), "top-by-value_max must survive")
        XCTAssertLessThanOrEqual(rows.count, 2 * 2) // bounded ~2N
    }

    func testSelectSurvivorsTiesBrokenByValueMax() {
        let rows = [
            ProcRow(ts: 0, subsystem: "cpu", pid: 1, name: "A", value: 0.5, valueMax: 0.9),
            ProcRow(ts: 0, subsystem: "cpu", pid: 2, name: "B", value: 0.5, valueMax: 0.6),
        ]
        let survivors = selectSurvivors(rows, topN: 1)
        // top-1 by value ties (both 0.5) -> broken by valueMax -> A wins; top-1 by valueMax
        // is also A. Union = {A}.
        XCTAssertEqual(survivors.map(\.name), ["A"])
    }

    // MARK: - DB-backed: minute rollover AVG/MAX + names present at 1m

    func testMinuteRollupKeepsNamesAndAggregates() throws {
        let store = try RecordingStore.temporary()
        defer { try? FileManager.default.removeItem(atPath: store.dbPool.path) }

        try store.dbPool.write { db in
            for i in 0..<60 {
                var s = ScalarRow(ts: i)
                s.cpuAvg = Double(i) / 100; s.cpuMax = Double(i) / 100
                s.procN = 1   // one attribution sample per 1s bucket
                try RowStore.upsert(s, into: Tier.s1.table, db)
                let p = ProcRow(ts: i, subsystem: "cpu", pid: 5, name: "Busy", value: 0.5, valueMax: 0.5)
                try RowStore.upsert(p, into: Tier.s1.procTable!, db)
            }
            // now is well past the minute so the 0..<60 bucket is sealed.
            _ = try Rollup.cascade(db, from: .s1, now: 120)
        }

        try store.dbPool.read { db in
            let m = try RowStore.scalars(in: Tier.m1.table, from: 0, to: 60, db)
            XCTAssertEqual(m.count, 1)
            XCTAssertEqual(m[0].cpuMax!, 0.59, accuracy: 1e-9)
            XCTAssertEqual(m[0].procN, 60)   // proc_n = sum of finer proc_n
            let procs = try RowStore.procs(in: Tier.m1.procTable!, from: 0, to: 60, db)
            XCTAssertEqual(procs.count, 1)
            XCTAssertEqual(procs[0].name, "Busy")   // names KEPT at 1m
            // Present in all 60 attribution samples at 0.5 -> true value 0.5 (denominator = 60).
            XCTAssertEqual(procs[0].value, 0.5, accuracy: 1e-9)
        }
    }

    // MARK: - DB-backed: sub-cadence does NOT deflate a sustained process (regression)

    func testSubCadenceDoesNotDeflateSustainedProcess() throws {
        // Attribution runs on a slower sub-cadence: only every 3rd 1s bucket carries a proc
        // row (20 samples in the minute). A process pegged at 0.8 in EVERY attribution sample
        // must roll up to 1m value == 0.8, NOT 0.8/3.
        let store = try RecordingStore.temporary()
        defer { try? FileManager.default.removeItem(atPath: store.dbPool.path) }

        try store.dbPool.write { db in
            for i in 0..<60 {
                var s = ScalarRow(ts: i)
                s.cpuAvg = 0.8; s.cpuMax = 0.8
                let hasAttribution = (i % 3 == 0)   // 20 of 60 ticks
                s.procN = hasAttribution ? 1 : 0
                try RowStore.upsert(s, into: Tier.s1.table, db)
                if hasAttribution {
                    let p = ProcRow(ts: i, subsystem: "cpu", pid: 99, name: "Pegged", value: 0.8, valueMax: 0.8)
                    try RowStore.upsert(p, into: Tier.s1.procTable!, db)
                }
            }
            _ = try Rollup.cascade(db, from: .s1, now: 120)
        }

        try store.dbPool.read { db in
            let m = try RowStore.scalars(in: Tier.m1.table, from: 0, to: 60, db)
            XCTAssertEqual(m[0].procN, 20, "proc_n = number of attribution samples in the minute")
            let p = try RowStore.procs(in: Tier.m1.procTable!, from: 0, to: 60, db).first { $0.pid == 99 }!
            XCTAssertEqual(p.value, 0.8, accuracy: 1e-9, "sustained process NOT deflated by sub-cadence factor")
            XCTAssertEqual(p.valueMax, 0.8, accuracy: 1e-9)
        }
    }

    // MARK: - DB-backed: hour rollover drops names (no proc_1h)

    func testHourRollupDropsNamesAndForeground() throws {
        let store = try RecordingStore.temporary()
        defer { try? FileManager.default.removeItem(atPath: store.dbPool.path) }

        try store.dbPool.write { db in
            for m in 0..<60 {
                let ts = m * 60
                var s = ScalarRow(ts: ts)
                s.cpuAvg = 0.4; s.cpuMax = 0.8; s.fgApp = "Xcode"
                try RowStore.upsert(s, into: Tier.m1.table, db)
                let p = ProcRow(ts: ts, subsystem: "cpu", pid: 9, name: "App", value: 0.4, valueMax: 0.8)
                try RowStore.upsert(p, into: Tier.m1.procTable!, db)
            }
            _ = try Rollup.cascade(db, from: .m1, now: 7200)
        }

        try store.dbPool.read { db in
            let h = try RowStore.scalars(in: Tier.h1.table, from: 0, to: 3600, db)
            XCTAssertEqual(h.count, 1)
            XCTAssertEqual(h[0].cpuMax!, 0.8, accuracy: 1e-9)
            XCTAssertNil(h[0].fgApp, "foreground app dropped at 1h (KTD4)")
            // proc_1h does not exist as a tier — Tier.h1.procTable is nil.
            XCTAssertNil(Tier.h1.procTable)
        }
    }

    // MARK: - DB-backed: tier-boundary overlap excludes open finer bucket

    func testCascadeExcludesOpenFinerBucket() throws {
        let store = try RecordingStore.temporary()
        defer { try? FileManager.default.removeItem(atPath: store.dbPool.path) }

        try store.dbPool.write { db in
            // 59 sealed 1s rows + one row in the NEXT minute that is in-progress.
            for i in 0..<60 { var s = ScalarRow(ts: i); s.cpuAvg = 1.0; s.cpuMax = 1.0; try RowStore.upsert(s, into: Tier.s1.table, db) }
            var open = ScalarRow(ts: 60); open.cpuAvg = 0.0; open.cpuMax = 0.0
            try RowStore.upsert(open, into: Tier.s1.table, db)
            // now is INSIDE minute [60,120); the [0,60) bucket is sealed, [60,120) is open.
            _ = try Rollup.cascade(db, from: .s1, now: 75)
        }
        try store.dbPool.read { db in
            let m = try RowStore.scalars(in: Tier.m1.table, from: 0, to: 120, db)
            XCTAssertEqual(m.count, 1, "only the sealed [0,60) minute rolls up")
            XCTAssertEqual(m[0].ts, 0)
            XCTAssertEqual(m[0].cpuAvg!, 1.0, accuracy: 1e-9) // open ts=60 excluded
        }
    }

    // MARK: - DB-backed: multi-hour catch-up rolls ALL completed buckets

    func testCatchUpRollsAllCompletedBuckets() throws {
        let store = try RecordingStore.temporary()
        defer { try? FileManager.default.removeItem(atPath: store.dbPool.path) }

        // 3 full minutes of 1s rows with a gap then resume — catch-up must roll all 3.
        try store.dbPool.write { db in
            for minute in 0..<3 {
                for s in 0..<60 {
                    var row = ScalarRow(ts: minute * 60 + s); row.cpuAvg = 0.5; row.cpuMax = 0.5
                    try RowStore.upsert(row, into: Tier.s1.table, db)
                }
            }
        }
        try store.runCatchUp(now: 3 * 60 + 30)   // now is inside minute 3
        try store.dbPool.read { db in
            let m = try RowStore.scalars(in: Tier.m1.table, from: 0, to: 3 * 60, db)
            XCTAssertEqual(m.count, 3, "all 3 sealed minutes rolled up, not just the latest")
        }
    }

    func testCatchUpIsIdempotent() throws {
        let store = try RecordingStore.temporary()
        defer { try? FileManager.default.removeItem(atPath: store.dbPool.path) }
        try store.dbPool.write { db in
            for s in 0..<60 { var r = ScalarRow(ts: s); r.cpuAvg = 0.5; r.cpuMax = 0.5; try RowStore.upsert(r, into: Tier.s1.table, db) }
        }
        try store.runCatchUp(now: 120)
        let firstCount = try store.dbPool.read { try RowStore.count(in: Tier.m1.table, $0) }
        try store.runCatchUp(now: 120)   // re-run
        let secondCount = try store.dbPool.read { try RowStore.count(in: Tier.m1.table, $0) }
        XCTAssertEqual(firstCount, secondCount, "catch-up re-run is a no-op")
    }

    // MARK: - DB-backed: forward jump / DST fabricates no buckets

    func testForwardJumpFabricatesNoIntermediateBuckets() throws {
        let store = try RecordingStore.temporary()
        defer { try? FileManager.default.removeItem(atPath: store.dbPool.path) }
        // One minute now, then a sample an hour later. No rows should exist in between.
        try store.dbPool.write { db in
            for s in 0..<60 { var r = ScalarRow(ts: s); r.cpuAvg = 0.5; r.cpuMax = 0.5; try RowStore.upsert(r, into: Tier.s1.table, db) }
            for s in 0..<60 { var r = ScalarRow(ts: 3600 + s); r.cpuAvg = 0.5; r.cpuMax = 0.5; try RowStore.upsert(r, into: Tier.s1.table, db) }
        }
        try store.runCatchUp(now: 3600 + 120)
        try store.dbPool.read { db in
            let m = try RowStore.scalars(in: Tier.m1.table, from: 0, to: 3600 + 60, db)
            // Only the two populated minutes roll up; the 58 empty intermediate minutes do not.
            XCTAssertEqual(m.count, 2)
            XCTAssertEqual(m.map(\.ts), [0, 3600])
        }
    }

    // MARK: - DB-backed: retention prune boundaries (KTD4)

    func testPruneDeletes1sBeyond48hAnd1mBeyond30d() throws {
        let store = try RecordingStore.temporary()
        defer { try? FileManager.default.removeItem(atPath: store.dbPool.path) }
        let now = 100 * 86_400   // day 100, epoch seconds
        try store.dbPool.write { db in
            // 1s rows: one just inside 48h, one just outside.
            var inside = ScalarRow(ts: now - 47 * 3600); inside.cpuAvg = 0.1
            var outside = ScalarRow(ts: now - 49 * 3600); outside.cpuAvg = 0.1
            try RowStore.upsert(inside, into: Tier.s1.table, db)
            try RowStore.upsert(outside, into: Tier.s1.table, db)
            // 1m rows: one inside 30d, one outside.
            var mIn = ScalarRow(ts: now - 29 * 86_400); mIn.cpuAvg = 0.1
            var mOut = ScalarRow(ts: now - 31 * 86_400); mOut.cpuAvg = 0.1
            try RowStore.upsert(mIn, into: Tier.m1.table, db)
            try RowStore.upsert(mOut, into: Tier.m1.table, db)
            // 1h row well in the past — must survive (2y retention).
            var hOld = ScalarRow(ts: now - 200 * 86_400); hOld.cpuAvg = 0.1
            try RowStore.upsert(hOld, into: Tier.h1.table, db)

            _ = try Rollup.prune(db, tier: .s1, now: now)
            _ = try Rollup.prune(db, tier: .m1, now: now)
            _ = try Rollup.prune(db, tier: .h1, now: now)
        }
        try store.dbPool.read { db in
            XCTAssertEqual(try RowStore.count(in: Tier.s1.table, db), 1)   // only inside-48h
            XCTAssertEqual(try RowStore.count(in: Tier.m1.table, db), 1)   // only inside-30d
            XCTAssertEqual(try RowStore.count(in: Tier.h1.table, db), 1)   // 1h intact
        }
    }

    // MARK: - DB-backed: large first prune stays batched (WAL bound)

    func testLargePruneIsBatched() throws {
        let store = try RecordingStore.temporary()
        defer { try? FileManager.default.removeItem(atPath: store.dbPool.path) }
        let now = 10 * 86_400
        // 25k aged 1s rows -> exceeds the 10k batch limit, exercising the loop.
        try store.dbPool.write { db in
            for i in 0..<25_000 {
                var r = ScalarRow(ts: i); r.cpuAvg = 0.1   // ts far older than 48h
                try RowStore.upsert(r, into: Tier.s1.table, db)
            }
        }
        let deleted = try store.dbPool.write { try Rollup.prune($0, tier: .s1, now: now) }
        XCTAssertEqual(deleted, 25_000)
        XCTAssertEqual(try store.dbPool.read { try RowStore.count(in: Tier.s1.table, $0) }, 0)
    }
}
