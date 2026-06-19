//
//  HistoryQueryTests.swift
//  U9 historical query layer: pure tier-selection + DB-backed gap/clamp/seam/snapshot
//  scenarios (KTD2/KTD4/KTD12). Pure tests need no DB; DB-backed tests populate a
//  RecordingStore.temporary() and read through the GRDB reader pool.
//
import XCTest
import GRDB
@testable import Momo

final class HistoryQueryTests: XCTestCase {

    // MARK: - Test fixtures

    /// Deterministic monotonic clock so RecordingStore's @Sendable closure captures no
    /// non-Sendable state (mirrors RecordingStoreTests.MonoCounter).
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

    private func sample(at ts: Int, cpu: Double) -> Sample {
        Sample(timestamp: Date(timeIntervalSince1970: Double(ts)),
               cpu: CPUSample(overall: cpu, perCore: [cpu]))
    }

    /// Write a ScalarRow directly into a tier table (lets a test stage an exact tier layout
    /// without driving the full ingest/rollup cascade).
    private func write(_ rows: [ScalarRow], into tier: Tier, _ store: RecordingStore) throws {
        try store.dbPool.write { db in
            for r in rows { try RowStore.upsert(r, into: tier.table, db) }
        }
    }

    private func scalarRow(ts: Int, cpuAvg: Double, cpuMax: Double) -> ScalarRow {
        var r = ScalarRow(ts: ts)
        r.cpuAvg = cpuAvg; r.cpuMax = cpuMax
        return r
    }

    // MARK: - Pure: tier selection by zoom (KTD4 / U9)

    func testSixHourWindowSelects1m() {
        let start = 0, end = 6 * 3600   // 21600s
        let tier = HistoryQueryPlan.selectTier(start: start, end: end, budget: 500)
        // 1s = 21600 pts (> budget), 1m = 360 pts (<= budget) -> 1m.
        XCTAssertEqual(tier, .m1)
        XCTAssertLessThanOrEqual(
            HistoryQueryPlan.bucketCount(span: end - start, bucketSeconds: tier.bucketSeconds), 500)
    }

    func testSixMonthWindowSelects1h() {
        let start = 0, end = 180 * 86_400   // ~6 months
        let tier = HistoryQueryPlan.selectTier(start: start, end: end, budget: 500)
        // Every tier exceeds the budget for a 6-month window -> coarsest (1h).
        XCTAssertEqual(tier, .h1)
    }

    func testShortRecentWindowSelects1s() {
        let start = 0, end = 120   // 2 minutes -> 120 1s buckets, within budget
        XCTAssertEqual(HistoryQueryPlan.selectTier(start: start, end: end, budget: 500), .s1)
    }

    func testTierNeverFinerThanRetention() {
        // A window 10 days old: the 1s tier (48h retention) no longer reaches it, so even a
        // short span at that age must not pick 1s.
        let now = 100 * 86_400
        let start = now - 10 * 86_400
        let end = start + 120   // a 2-minute span that would fit 1s by budget alone
        let tier = HistoryQueryPlan.selectTier(start: start, end: end, budget: 500, now: now)
        XCTAssertNotEqual(tier, .s1)
        XCTAssertEqual(tier, .m1)   // 1m retains 30d, fits budget
    }

    func testBucketCountRoundsUpPartialTrailingBucket() {
        XCTAssertEqual(HistoryQueryPlan.bucketCount(span: 61, bucketSeconds: 60), 2)
        XCTAssertEqual(HistoryQueryPlan.bucketCount(span: 60, bucketSeconds: 60), 1)
        XCTAssertEqual(HistoryQueryPlan.bucketCount(span: 0, bucketSeconds: 60), 0)
    }

    // MARK: - DB: happy path point budget bound

    func testQueryReturnsWithinBudget() throws {
        let store = try makeStore(); defer { cleanup(store) }
        // Stage 360 one-minute rows (a 6h window). Query must select 1m and stay <= budget.
        let rows = (0..<360).map { scalarRow(ts: $0 * 60, cpuAvg: 0.4, cpuMax: 0.9) }
        try write(rows, into: .m1, store)

        let q = HistoryQuery(dbPool: store.dbPool, budget: 500)
        let series = try q.series(start: 0, end: 6 * 3600, now: 6 * 3600)
        XCTAssertEqual(series.tier, .m1)
        XCTAssertLessThanOrEqual(series.rows.count, 500)
        XCTAssertEqual(series.rows.count, 360)
        // AVG and MAX series both carried (KTD4/KTD12).
        XCTAssertEqual(series.rows.first?.cpuAvg, 0.4)
        XCTAssertEqual(series.rows.first?.cpuMax, 0.9)
    }

    // MARK: - DB: gap = absence of rows -> explicit gap marker, never interpolation

    func testWindowSpanningGapReturnsGapMarker() throws {
        let store = try makeStore(); defer { cleanup(store) }
        // 1s rows for [0,10) and [20,30); the middle [10,20) is ABSENT (a recorded gap).
        var rows = (0..<10).map { scalarRow(ts: $0, cpuAvg: 0.3, cpuMax: 0.3) }
        rows += (20..<30).map { scalarRow(ts: $0, cpuAvg: 0.3, cpuMax: 0.3) }
        try write(rows, into: .s1, store)

        let q = HistoryQuery(dbPool: store.dbPool)
        let series = try q.series(start: 0, end: 30, now: 30)
        XCTAssertEqual(series.tier, .s1)

        // Exactly one gap, covering [10,20).
        let gaps = series.points.compactMap { point -> (Int, Int)? in
            if case .gap(let from, let to) = point { return (from, to) } else { return nil }
        }
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps.first?.0, 10)
        XCTAssertEqual(gaps.first?.1, 20)
        XCTAssertEqual(series.rows.count, 20)   // 10 + 10 present rows, no interpolation
    }

    func testPresentRowWithNullMetricIsNotAGap() throws {
        let store = try makeStore(); defer { cleanup(store) }
        // A row that exists but has NULL cpu (sensor absent) — must be a .sample, not a .gap.
        var nullRow = ScalarRow(ts: 5)   // every metric nil
        nullRow.memUsedAvg = 100         // some other metric present to be unambiguous
        try write([scalarRow(ts: 4, cpuAvg: 0.2, cpuMax: 0.2), nullRow], into: .s1, store)

        let q = HistoryQuery(dbPool: store.dbPool)
        let series = try q.series(start: 4, end: 6, now: 6)
        // No gaps — both ts present even though row 5's cpu is NULL.
        XCTAssertFalse(series.points.contains { if case .gap = $0 { return true } else { return false } })
        XCTAssertEqual(series.rows.count, 2)
        XCTAssertNil(series.rows.last?.cpuAvg)        // NULL metric preserved as nil
        XCTAssertEqual(series.rows.last?.memUsedAvg, 100)
    }

    // MARK: - DB: clamp to oldest retained data + indicate truncation

    func testWindowEarlierThanOldestDataClampsAndFlagsTruncation() throws {
        let store = try makeStore(); defer { cleanup(store) }
        // Oldest 1s row is at ts=100; query starts at ts=0 (before any data).
        let rows = (100..<110).map { scalarRow(ts: $0, cpuAvg: 0.5, cpuMax: 0.5) }
        try write(rows, into: .s1, store)

        let q = HistoryQuery(dbPool: store.dbPool)
        let series = try q.series(start: 0, end: 110, now: 110)
        XCTAssertTrue(series.truncatedToOldest)
        XCTAssertEqual(series.resolvedStart, 100)   // clamped forward to oldest row
        // No fabricated leading gap before the oldest row.
        if case .gap = series.points.first { XCTFail("clamped series should not lead with a gap") }
        XCTAssertEqual(series.rows.count, 10)
    }

    func testEmptyWindowReturnsSingleGapNoTruncation() throws {
        let store = try makeStore(); defer { cleanup(store) }
        let q = HistoryQuery(dbPool: store.dbPool)
        let series = try q.series(start: 0, end: 10, now: 10)
        XCTAssertFalse(series.truncatedToOldest)
        XCTAssertTrue(series.rows.isEmpty)
        XCTAssertEqual(series.points.count, 1)
        if case .gap(let from, let to) = series.points.first {
            XCTAssertEqual(from, 0); XCTAssertEqual(to, 10)
        } else { XCTFail("expected a single gap for an empty window") }
    }

    // MARK: - DB: tier seam — no double-count across overlapping buckets

    func testStraddlingTierSeamPicksOneTierNoDoubleCount() throws {
        let store = try makeStore(); defer { cleanup(store) }
        // Populate BOTH tiers over the same wall-time region so a naive union would double
        // count. The 1m tier covers [0, 7200) (2h of minute buckets); the 1s tier covers a
        // sub-window. A window that straddles the 48h seam-age must resolve to exactly ONE
        // tier and count each region once.
        let mRows = (0..<120).map { scalarRow(ts: $0 * 60, cpuAvg: 0.4, cpuMax: 0.8) }   // 2h @1m
        let sRows = (0..<600).map { scalarRow(ts: $0, cpuAvg: 0.4, cpuMax: 0.8) }        // 10m @1s
        try write(mRows, into: .m1, store)
        try write(sRows, into: .s1, store)

        // A 2-hour window with budget 500: 1s would be 7200 pts (>budget) -> selects 1m only.
        let q = HistoryQuery(dbPool: store.dbPool, budget: 500)
        let series = try q.series(start: 0, end: 7200, now: 7200)
        XCTAssertEqual(series.tier, .m1)
        // Exactly the 1m rows, no 1s rows mixed in -> no double-count of overlapping buckets.
        XCTAssertEqual(series.rows.count, 120)
        // Bucket starts are all minute-aligned (read straight off the single chosen tier).
        XCTAssertTrue(series.rows.allSatisfy { $0.ts % 60 == 0 })
    }

    // MARK: - DB: concurrent read while ingest is writing -> consistent snapshot, no BUSY

    func testConcurrentReadDuringIngestNoBusy() throws {
        let store = try makeStore(); defer { cleanup(store) }
        let q = HistoryQuery(dbPool: store.dbPool, budget: 5000)

        // Feeder: drive ingest on a background queue while the main thread reads repeatedly.
        let feederDone = expectation(description: "feeder done")
        let feeder = DispatchQueue(label: "test.feeder")
        feeder.async {
            for i in 0..<600 { store.receive(self.sample(at: i, cpu: Double(i % 100) / 100)) }
            store.receive(self.sample(at: 600, cpu: 0))   // force a final rollover/flush
            store.flushPending()
            feederDone.fulfill()
        }

        // Concurrent reader: query the whole window many times. The WAL reader pool must
        // always return a consistent snapshot without throwing SQLITE_BUSY.
        for _ in 0..<200 {
            XCTAssertNoThrow(try q.series(start: 0, end: 700, now: 700))
        }
        wait(for: [feederDone], timeout: 10)

        // After ingest completes, the recorded rows are readable and ascending.
        let series = try q.series(start: 0, end: 700, now: 700)
        XCTAssertGreaterThan(series.rows.count, 0)
        let ts = series.rows.map(\.ts)
        XCTAssertEqual(ts, ts.sorted())
    }

    // MARK: - DB: end-to-end via real ingest (rollup-produced rows query coherently)

    func testIngestedMinuteQueryableAt1mTier() throws {
        let store = try makeStore(); defer { cleanup(store) }
        for i in 0..<60 { store.receive(sample(at: i, cpu: Double(i) / 100)) }
        store.receive(sample(at: 60, cpu: 0))   // rollover -> flush + cascade produces 1m row
        store.flushPending()

        let q = HistoryQuery(dbPool: store.dbPool, budget: 500)
        // A 1h window selects 1m (3600/60 = 60 pts <= budget); the rolled-up minute is present.
        let series = try q.series(start: 0, end: 3600, now: 3600)
        XCTAssertEqual(series.tier, .m1)
        XCTAssertEqual(series.rows.count, 1)
        XCTAssertEqual(series.rows.first?.cpuMax ?? 0, 0.59, accuracy: 1e-9)
    }
}
