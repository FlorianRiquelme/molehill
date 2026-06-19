//
//  ScrubBackTests.swift
//  U10 scrub-back data resolution (R8 / AE1). The drag itself is manual; what is unit-testable
//  is the `.at(Date)` resolution behind the panel's viewTime seam — `HistoricalResolver`. These
//  tests populate a `RecordingStore.temporary()` with synthetic recorded rows, then assert the
//  resolution at a past timestamp returns the values RECORDED at that timestamp (not current
//  ones), surfaces a gap as the gap state (no interpolation), and stays accurate across a tier
//  boundary. The "return to live" edge is the panel routing `.live` back to the ring; here we
//  assert the historical resolver itself reports the live edge correctly.
//
import XCTest
import GRDB
@testable import Momo

final class ScrubBackTests: XCTestCase {

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

    private func write(_ rows: [ScalarRow], into tier: Tier, _ store: RecordingStore) throws {
        try store.dbPool.write { db in
            for r in rows { try RowStore.upsert(r, into: tier.table, db) }
        }
    }

    private func cpuRow(ts: Int, avg: Double, max: Double) -> ScalarRow {
        var r = ScalarRow(ts: ts); r.cpuAvg = avg; r.cpuMax = max; return r
    }

    // MARK: - AE1: scrub to ~2 days ago returns the recorded values, not current

    /// Several "days" of recorded 1m rows where CPU encodes its own timestamp (avg = ts/scale),
    /// so the resolver's output is checkable against the exact recorded value. The cursor two
    /// days back must resolve to the row recorded then — distinct from the latest ("current").
    func testScrubTwoDaysAgoReturnsRecordedValues() throws {
        let store = try makeStore(); defer { cleanup(store) }
        let now = 5 * 86_400                       // pretend "now" is day 5
        // One 1m row per minute for 5 days. avg encodes the minute index so each row is unique.
        let minuteCount = 5 * 24 * 60
        let rows = (0..<minuteCount).map { i -> ScalarRow in
            let ts = i * 60
            return cpuRow(ts: ts, avg: Double(i % 100) / 100.0, max: Double((i % 100) + 1) / 100.0)
        }
        try write(rows, into: .m1, store)

        let query = HistoryQuery(dbPool: store.dbPool)
        let twoDaysAgo = Date(timeIntervalSince1970: Double(now - 2 * 86_400))
        let res = try HistoricalResolver.resolve(
            date: twoDaysAgo, target: .cpu, query: query,
            now: Date(timeIntervalSince1970: Double(now)))

        // The recorded row at exactly two days ago.
        let cursorMinute = (now - 2 * 86_400) / 60
        let expectedAvg = Double(cursorMinute % 100) / 100.0
        let expectedMax = Double((cursorMinute % 100) + 1) / 100.0

        let cursorValue = try XCTUnwrap(res.cursorValue)
        XCTAssertEqual(cursorValue, expectedAvg, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(res.cursorValueMax), expectedMax, accuracy: 1e-9)
        XCTAssertFalse(res.cursorInGap)

        // And it is NOT the current (latest) value.
        let latestMinute = minuteCount - 1
        let latestAvg = Double(latestMinute % 100) / 100.0
        XCTAssertNotEqual(cursorValue, latestAvg, "Scrub-back must return recorded, not current")

        // The chart series is non-empty and MAX is surfaced alongside AVG (KTD12).
        XCTAssertFalse(res.points.isEmpty)
        XCTAssertTrue(res.points.allSatisfy { $0.valueMax != nil })
    }

    // MARK: - Edge: scrubbing into a recorded gap yields the gap state (no interpolation)

    func testScrubIntoGapYieldsGapState() throws {
        let store = try makeStore(); defer { cleanup(store) }
        // 1s rows on either side of a 10-minute hole (a sleep gap). Query a window straddling it.
        let before = (0..<60).map { cpuRow(ts: $0, avg: 0.5, max: 0.6) }
        let after = (660..<720).map { cpuRow(ts: $0, avg: 0.5, max: 0.6) }   // resumes after 11 min
        try write(before + after, into: .s1, store)

        let query = HistoryQuery(dbPool: store.dbPool)
        // Cursor parked in the hole (ts 300, ~5 min in).
        let cursor = Date(timeIntervalSince1970: 300)
        let res = try HistoricalResolver.resolve(
            date: cursor, target: .cpu, query: query, window: 720,
            now: Date(timeIntervalSince1970: 720))

        XCTAssertTrue(res.cursorInGap, "Cursor in a recorded gap must report the gap state")
        XCTAssertNil(res.cursorValue, "No interpolated/stale value across a gap")
        XCTAssertFalse(res.frame.gaps.isEmpty, "The scrub track must mark the gap region")
        // The gap fraction must contain the cursor's fraction.
        XCTAssertTrue(res.frame.cursorInGap(cursor))
    }

    // MARK: - Edge: scrubbing to the live edge resolves the most recent recorded row

    func testScrubToLiveEdgeResolvesLatestRow() throws {
        let store = try makeStore(); defer { cleanup(store) }
        let rows = (0..<120).map { cpuRow(ts: $0, avg: Double($0) / 200.0, max: Double($0) / 100.0) }
        try write(rows, into: .s1, store)

        let query = HistoryQuery(dbPool: store.dbPool)
        let nowTs = 119
        let res = try HistoricalResolver.resolve(
            date: Date(timeIntervalSince1970: Double(nowTs)), target: .cpu, query: query, window: 120,
            now: Date(timeIntervalSince1970: Double(nowTs)))

        XCTAssertFalse(res.cursorInGap)
        XCTAssertEqual(try XCTUnwrap(res.cursorValue), Double(nowTs) / 200.0, accuracy: 1e-9)
        // The live edge of the window is "now".
        XCTAssertEqual(res.frame.windowEnd.timeIntervalSince1970, Double(nowTs), accuracy: 1.0)
    }

    // MARK: - Edge: tier boundary (1s -> 1m) keeps the reported cursor time accurate

    /// A window old enough that the 1s tier is pruned forces 1m resolution. The resolved cursor
    /// value must come from the 1m row covering the cursor minute — its reported time stays the
    /// bucket start, not drifted.
    func testTierBoundaryKeepsCursorTimeAccurate() throws {
        let store = try makeStore(); defer { cleanup(store) }
        let now = 10 * 86_400                       // 10 days "now" — 1s (48h) no longer retains
        // 1m rows around a cursor 5 days back.
        let baseMinute = (now - 5 * 86_400) / 60
        let rows = (0..<200).map { i -> ScalarRow in
            cpuRow(ts: (baseMinute + i) * 60, avg: Double(i) / 100.0, max: Double(i) / 50.0)
        }
        try write(rows, into: .m1, store)
        // Stage a 1s row at the same wall time to prove tier selection ignores it (pruned-age).
        try write([cpuRow(ts: (baseMinute + 100) * 60, avg: 9.99, max: 9.99)], into: .s1, store)

        let query = HistoryQuery(dbPool: store.dbPool)
        // Cursor at minute baseMinute+100, plus 17 seconds (mid-bucket).
        let cursorTs = (baseMinute + 100) * 60 + 17
        let res = try HistoricalResolver.resolve(
            date: Date(timeIntervalSince1970: Double(cursorTs)), target: .cpu, query: query,
            window: 3600, now: Date(timeIntervalSince1970: Double(now)))

        // Must resolve from the 1m row (value 100/100 = 1.0), NOT the 1s decoy (9.99).
        XCTAssertEqual(try XCTUnwrap(res.cursorValue), 1.0, accuracy: 1e-9)
        // The plotted point for that bucket is timestamped at the bucket start, not the cursor.
        let pointAtCursor = res.points.first { Int($0.time.timeIntervalSince1970) == (baseMinute + 100) * 60 }
        XCTAssertNotNil(pointAtCursor, "Cursor's bucket point keeps its bucket-start time")
    }

    // MARK: - Per-target AVG/MAX column mapping (KTD12 dual-path)

    func testTargetColumnMapping() throws {
        var r = ScalarRow(ts: 0)
        r.cpuAvg = 0.3; r.cpuMax = 0.8
        r.memUsedAvg = 4_000; r.memUsedMax = 6_000; r.memTotal = 8_000
        r.diskReadAvg = 100; r.diskWriteAvg = 50; r.diskReadMax = 300; r.diskWriteMax = 80
        r.netRxAvg = 10; r.netTxAvg = 5; r.netRxMax = 40; r.netTxMax = 20
        r.tempMaxAvg = 55; r.tempMaxMax = 71

        let cpu = try XCTUnwrap(DrillTarget.cpu.historicalScalar(r))
        XCTAssertEqual(cpu.avg, 0.3); XCTAssertEqual(cpu.max, 0.8)

        let mem = try XCTUnwrap(DrillTarget.memory.historicalScalar(r))
        XCTAssertEqual(mem.avg, 0.5, accuracy: 1e-9)              // 4000/8000
        XCTAssertEqual(try XCTUnwrap(mem.max), 0.75, accuracy: 1e-9)   // 6000/8000

        let disk = try XCTUnwrap(DrillTarget.disk.historicalScalar(r))
        XCTAssertEqual(disk.avg, 150)                       // 100 + 50
        XCTAssertEqual(disk.max, 380)                       // 300 + 80

        let net = try XCTUnwrap(DrillTarget.network.historicalScalar(r))
        XCTAssertEqual(net.avg, 15)                         // 10 + 5
        XCTAssertEqual(net.max, 60)                         // 40 + 20

        let sensors = try XCTUnwrap(DrillTarget.sensors.historicalScalar(r))
        XCTAssertEqual(sensors.avg, 55); XCTAssertEqual(sensors.max, 71)

        // A present row with a NULL metric for the target yields no point (not a gap).
        let empty = ScalarRow(ts: 0)
        XCTAssertNil(DrillTarget.cpu.historicalScalar(empty))
    }

    // MARK: - Full ingest path: recorded via receive()+rollup is scrubbable at 1m

    /// Drives the real ingest/rollup cascade (not direct writes) so AE1's "as recorded"
    /// guarantee is validated end-to-end through the store, then scrubbed back at the 1m tier.
    func testIngestedHistoryIsScrubbable() throws {
        let store = try makeStore(); defer { cleanup(store) }
        // One full minute of 1s ticks with a mid-minute CPU spike, then roll over to flush+cascade.
        for i in 0..<60 {
            let cpu = i == 30 ? 0.95 : 0.10        // spike at second 30
            store.receive(Sample(timestamp: Date(timeIntervalSince1970: Double(i)),
                                  cpu: CPUSample(overall: cpu, perCore: [cpu])))
        }
        store.receive(Sample(timestamp: Date(timeIntervalSince1970: 60),
                             cpu: CPUSample(overall: 0.1, perCore: [0.1])))   // rollover
        store.flushPending()
        try store.runCatchUp(now: 120)

        let query = HistoryQuery(dbPool: store.dbPool)
        // Scrub to within the first minute; resolve at the 1m tier (window spans minutes).
        let res = try HistoricalResolver.resolve(
            date: Date(timeIntervalSince1970: 30), target: .cpu, query: query,
            window: 3600, now: Date(timeIntervalSince1970: 120))

        let avg = try XCTUnwrap(res.cursorValue)
        let mx = try XCTUnwrap(res.cursorValueMax)
        // The bucket MAX preserves the spike that the AVG hides (KTD12 — surfaced alongside AVG).
        XCTAssertEqual(mx, 0.95, accuracy: 1e-9)
        XCTAssertLessThan(avg, mx, "AVG must be below the recorded spike MAX")
    }
}
