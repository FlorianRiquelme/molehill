//
//  RecordingStoreTests.swift
//  Ingest, clock guard, re-flush/partial-reflush, persistence + migrator + too-new,
//  crash scenarios, privacy posture (KTD2/KTD4/KTD4a/KTD4b).
//
import XCTest
import GRDB
@testable import Momo

final class RecordingStoreTests: XCTestCase {

    // Helper: a Sample at a given epoch second with optional metrics.
    private func sample(
        at ts: Int, cpu: Double? = nil, temp: Double? = nil,
        fg: String? = nil, procs: [Subsystem: [ProcessAttribution]] = [:]
    ) -> Sample {
        Sample(
            timestamp: Date(timeIntervalSince1970: Double(ts)),
            cpu: cpu.map { CPUSample(overall: $0, perCore: [$0]) },
            sensors: temp.map { SensorSample(temperatures: [SensorReading(key: "T", label: "T", celsius: $0)], fans: [], thermalState: .nominal) },
            attribution: procs.isEmpty ? nil : AttributionSample(bySubsystem: procs),
            context: CorrelatedState(foregroundApp: fg)
        )
    }

    private func makeStore() throws -> RecordingStore {
        // Deterministic monotonic clock: advances +1s per read, independent of the test
        // instance so the @Sendable closure captures no non-Sendable state.
        let counter = MonoCounter()
        return try RecordingStore.temporary(monoClock: { counter.next() })
    }

    /// Thread-safe monotonic counter for the injected companion clock.
    private final class MonoCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 0
        func next() -> UInt64 {
            lock.lock(); defer { lock.unlock() }
            value += 1_000_000_000
            return value
        }
    }

    private func cleanup(_ store: RecordingStore) {
        let path = store.dbPool.path
        for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) }
    }

    // MARK: - Happy path ingest: a full minute -> one 1s row per second, then a 1m row.

    func testIngestFullMinuteRollsToOneMinuteRow() throws {
        let store = try makeStore(); defer { cleanup(store) }
        for i in 0..<60 { store.receive(sample(at: i, cpu: Double(i) / 100)) }
        store.receive(sample(at: 60, cpu: 0.0))   // rollover into next minute -> flush + cascade
        store.flushPending()

        try store.dbPool.read { db in
            XCTAssertGreaterThanOrEqual(try RowStore.count(in: Tier.s1.table, db), 60)
            let m = try RowStore.scalars(in: Tier.m1.table, from: 0, to: 60, db)
            XCTAssertEqual(m.count, 1)
            XCTAssertEqual(m[0].cpuMax!, 0.59, accuracy: 1e-9)
        }
    }

    // MARK: - Re-flush in-progress bucket updates, never duplicates.

    func testReflushSameBucketUpdatesNotDuplicates() throws {
        let store = try makeStore(); defer { cleanup(store) }
        // Two ticks in the same second-bucket... actually same ts -> same 1s bucket.
        store.receive(sample(at: 5, cpu: 0.2))
        store.flushPending()  // flush bucket [5,6)
        store.receive(sample(at: 5, cpu: 0.8))  // same bucket, re-buffered
        store.flushPending()
        try store.dbPool.read { db in
            let rows = try RowStore.scalars(in: Tier.s1.table, from: 5, to: 6, db)
            XCTAssertEqual(rows.count, 1, "INSERT OR REPLACE on same ts = update, not duplicate")
        }
    }

    // MARK: - Sub-cadence partial re-flush doesn't NULL-wipe columns.

    func testPartialReflushDoesNotNullWipe() throws {
        let store = try makeStore(); defer { cleanup(store) }
        // Tick 1: CPU only. Flush. Tick 2 (same bucket): sensors arrive. Flush.
        store.receive(sample(at: 10, cpu: 0.5))
        store.flushPending()
        store.receive(sample(at: 10, cpu: 0.5, temp: 70))
        store.flushPending()
        try store.dbPool.read { db in
            let r = try RowStore.scalars(in: Tier.s1.table, from: 10, to: 11, db)[0]
            XCTAssertEqual(r.cpuAvg!, 0.5, accuracy: 1e-9, "earlier column not wiped")
            XCTAssertEqual(r.tempMaxMax!, 70, accuracy: 1e-9, "later sub-cadence column present")
        }
    }

    // MARK: - Per-process ingest end-to-end (full-bucket denominator + value_max).

    func testPerProcessIngestDenominatorAndPeak() throws {
        let store = try makeStore(); defer { cleanup(store) }
        // pid 42 appears in 10 of 60 1s ticks in minute 0 at value 0.6.
        for i in 0..<60 {
            let procs: [Subsystem: [ProcessAttribution]] = (i < 10)
                ? [.cpu: [ProcessAttribution(pid: 42, name: "X", subsystem: .cpu, value: 0.6, restricted: false)]]
                : [:]
            store.receive(sample(at: i, cpu: 0.5, procs: procs))
        }
        store.receive(sample(at: 60, cpu: 0.0))   // rollover -> flush minute 0 + cascade
        store.flushPending()
        try store.dbPool.read { db in
            let p = try RowStore.procs(in: Tier.m1.procTable!, from: 0, to: 60, db).first { $0.pid == 42 }!
            XCTAssertEqual(p.value, 0.6 * 10 / 60, accuracy: 1e-9)
            XCTAssertEqual(p.valueMax, 0.6, accuracy: 1e-9)
        }
    }

    // MARK: - Clock guard (pure decisions, KTD2).

    func testClockGuardFirstSampleAccepts() {
        XCTAssertEqual(ClockGuard.decide(lastTs: nil, sampleTs: 100, lastMono: nil, sampleMono: 0), .accept)
    }
    func testClockGuardForwardAccepts() {
        XCTAssertEqual(ClockGuard.decide(lastTs: 100, sampleTs: 101, lastMono: 0, sampleMono: 1), .accept)
    }
    func testClockGuardSmallBackwardIsSlew() {
        // A few seconds backward (< one minute) is a minor NTP slew.
        XCTAssertEqual(ClockGuard.slewThresholdSeconds, 60)
        XCTAssertEqual(
            ClockGuard.decide(lastTs: 10_000, sampleTs: 9_995, lastMono: 0, sampleMono: 1),
            .rejectSlew)
    }
    func testClockGuardSustainedBackwardIsAuthoritative() {
        // 600s backward jump (many buckets) -> authoritative reset.
        XCTAssertEqual(
            ClockGuard.decide(lastTs: 10_000, sampleTs: 9_400, lastMono: 0, sampleMono: 1),
            .authoritativeReset)
    }
    func testClockGuardThresholdBoundaryIsAuthoritative() {
        // Exactly one minute back is no longer a slew.
        XCTAssertEqual(
            ClockGuard.decide(lastTs: 10_000, sampleTs: 9_940, lastMono: 0, sampleMono: 1),
            .authoritativeReset)
    }

    // MARK: - Clock backward: sustained jump seals tail, overwrites future, doesn't lose.

    func testSustainedBackwardJumpIsAuthoritative() throws {
        let store = try makeStore(); defer { cleanup(store) }
        // Stream A: future-dated (stale RTC said it was t=10000..10009).
        for i in 0..<10 { store.receive(sample(at: 10_000 + i, cpu: 0.9)) }
        store.flushPending()
        // Clock corrected backward to t=100 (sustained jump). New authoritative stream.
        for i in 0..<5 { store.receive(sample(at: 100 + i, cpu: 0.1)) }
        store.flushPending()
        try store.dbPool.read { db in
            // The pre-jump tail is sealed (still present), and the corrected stream is written.
            let sealed = try RowStore.scalars(in: Tier.s1.table, from: 10_000, to: 10_010, db)
            XCTAssertFalse(sealed.isEmpty, "pre-jump tail sealed, not erased")
            let corrected = try RowStore.scalars(in: Tier.s1.table, from: 100, to: 105, db)
            XCTAssertFalse(corrected.isEmpty, "corrected authoritative stream recorded")
        }
    }

    // MARK: - Clock backward small (slew): coarse-bucket slew folds, no sealed overwrite.

    func testSmallBackwardSlewDoesNotOverwriteSealed() throws {
        let store = try makeStore(); defer { cleanup(store) }
        store.receive(sample(at: 300, cpu: 0.5))   // seals bucket [300,301) on next rollover
        store.receive(sample(at: 302, cpu: 0.5))   // rollover flushes [300,301); current=[302,303)
        store.flushPending()
        let sealedBefore = try store.dbPool.read { try RowStore.scalars(in: Tier.s1.table, from: 300, to: 301, $0) }
        XCTAssertEqual(sealedBefore.count, 1)
        // A 4s backward slew (< 60s threshold): must fold into the current bucket, NOT rewrite
        // the sealed [300,301) bucket.
        store.receive(sample(at: 298, cpu: 0.99))
        store.flushPending()
        let sealedAfter = try store.dbPool.read { try RowStore.scalars(in: Tier.s1.table, from: 300, to: 301, $0) }
        XCTAssertEqual(sealedBefore, sealedAfter, "sealed [300,301) bucket unchanged by slew")
        // And no row was created at the slewed ts 298.
        let slewed = try store.dbPool.read { try RowStore.scalars(in: Tier.s1.table, from: 298, to: 299, $0) }
        XCTAssertTrue(slewed.isEmpty, "slew folded into current bucket, no new earlier row")
    }

    // MARK: - Crash (mid-cascade): 1m written before 1s pruned -> reopen + catch-up = no loss.

    func testMidCascadeCrashNoLossAfterReopen() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("momo-crash-\(UUID()).sqlite")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + s) } }

        do {
            let store = try RecordingStore(url: url)
            try store.dbPool.write { db in
                for s in 0..<60 { var r = ScalarRow(ts: s); r.cpuAvg = 0.5; r.cpuMax = 0.5; try RowStore.upsert(r, into: Tier.s1.table, db) }
                // Simulate: write 1m row but "crash" before pruning the 1s rows (prune is
                // age-driven so 1s rows here aren't aged anyway — both tiers retain the data).
                _ = try Rollup.cascade(db, from: .s1, now: 120)
            }
            // store deallocs ~ process death
        }
        // Reopen + catch-up.
        let reopened = try RecordingStore(url: url)
        try reopened.runCatchUp(now: 120)
        try reopened.dbPool.read { db in
            XCTAssertEqual(try RowStore.count(in: Tier.m1.table, db), 1, "1m present after reopen")
            XCTAssertGreaterThan(try RowStore.count(in: Tier.s1.table, db), 0, "no data loss")
        }
        // Re-run catch-up is a no-op.
        try reopened.runCatchUp(now: 120)
        try reopened.dbPool.read { db in
            XCTAssertEqual(try RowStore.count(in: Tier.m1.table, db), 1)
        }
    }

    // MARK: - Crash (unflushed buffer): kill without flush -> consistent, <= 1 finest lost.

    func testUnflushedBufferLossBoundedToOneBucket() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("momo-kill-\(UUID()).sqlite")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + s) } }
        do {
            let store = try RecordingStore(url: url)
            store.receive(sample(at: 0, cpu: 0.5))   // bucket [0,1)
            store.receive(sample(at: 1, cpu: 0.5))   // rollover flushes [0,1); [1,2) buffered
            // "kill" without flushPending: bucket [1,2) is lost, [0,1) durable.
        }
        let reopened = try RecordingStore(url: url)
        try reopened.dbPool.read { db in
            let rows = try RowStore.scalars(in: Tier.s1.table, from: 0, to: 10, db)
            XCTAssertEqual(rows.map(\.ts), [0], "exactly the flushed bucket survived; <=1 lost")
        }
    }

    // MARK: - Persistence + migrator across restart.

    func testPersistenceAcrossReopen() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("momo-persist-\(UUID()).sqlite")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + s) } }
        do {
            let store = try RecordingStore(url: url)
            store.receive(sample(at: 42, cpu: 0.5))
            store.flushPending()
        }
        let reopened = try RecordingStore(url: url)   // migrator applies cleanly on populated DB
        try reopened.dbPool.read { db in
            XCTAssertEqual(try RowStore.scalars(in: Tier.s1.table, from: 42, to: 43, db).count, 1)
        }
    }

    // MARK: - Too-new DB detection via hasBeenSuperseded.

    func testTooNewDatabaseDetected() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("momo-toonew-\(UUID()).sqlite")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + s) } }
        // Write a DB with a migration our binary doesn't know.
        let pool = try DatabasePool(path: url.path)
        var future = DatabaseMigrator()
        future.registerMigration("v1_tiered_schema") { _ in }
        future.registerMigration("v999_future") { _ in }
        try future.migrate(pool)
        try pool.close()

        XCTAssertThrowsError(try RecordingStore(url: url)) { error in
            XCTAssertEqual(error as? RecordingStore.StoreError, .databaseTooNew)
        }
    }

    // MARK: - Privacy proxies (KTD4b): secure_delete ON, files 0o600, excluded-from-backup.

    func testPrivacyPosture() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("momo-priv-\(UUID()).sqlite")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + s) } }
        let store = try RecordingStore(url: url)
        store.receive(sample(at: 0, cpu: 0.5))
        store.flushPending()   // forces -wal/-shm to exist

        // secure_delete reads back ON.
        let secureDelete = try store.dbPool.read { db in
            try Int.fetchOne(db, sql: "PRAGMA secure_delete")
        }
        XCTAssertEqual(secureDelete, 1)

        // 0o600 on db + -wal + -shm (those that exist).
        for s in ["", "-wal", "-shm"] {
            let p = url.path + s
            if FileManager.default.fileExists(atPath: p) {
                let attrs = try FileManager.default.attributesOfItem(atPath: p)
                let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
                XCTAssertEqual(perms, 0o600, "\(p) should be owner-only")
            }
        }

        // Excluded from backup.
        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    // MARK: - Checkpoint blocked by open reader defers gracefully.

    func testCheckpointBlockedByOpenReaderDefersGracefully() throws {
        let store = try makeStore(); defer { cleanup(store) }
        store.receive(sample(at: 0, cpu: 0.5))
        // Hold a long read transaction (simulated scrub) while flushing/checkpointing.
        let expectation = expectation(description: "reader holds open during flush")
        let readerStarted = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? store.dbPool.read { db in
                _ = try RowStore.count(in: Tier.s1.table, db)
                readerStarted.signal()
                _ = release.wait(timeout: .now() + 5)   // hold the read snapshot
            }
            expectation.fulfill()
        }
        readerStarted.wait()
        // Flush + checkpoint must not throw even though the reader blocks TRUNCATE.
        XCTAssertNoThrow(store.flushPending())
        release.signal()
        wait(for: [expectation], timeout: 5)
        // After reader closes, the store still works.
        XCTAssertNoThrow(try store.runCatchUp(now: 120))
    }
}
