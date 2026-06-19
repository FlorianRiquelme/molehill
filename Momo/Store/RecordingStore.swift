//
//  RecordingStore.swift
//  Persistent GRDB DatabasePool (WAL) ingest, conforming to SampleReceiver (KTD12).
//
//  Lifecycle: the governor's SampleSink fans each tick to `receive(_:)` on the collection
//  queue. The store buffers the current finest (1s) bucket in memory there, and on bucket
//  rollover flushes the SEALED bucket to samples_1s (INSERT OR REPLACE), then drives the
//  rollup cascade + retention prune on GRDB's serialized writer (KTD2). Reads (UI/U9) use
//  the concurrent reader pool and never block ingest.
//
//  Concurrency (Swift 6 strict): the in-memory buffer is confined to a private serial queue
//  so `receive(_:)` is safe to call from the governor queue; the DatabasePool owns its own
//  writer/reader serialization. Nothing here is `@MainActor`.
//
import Foundation
import GRDB

final class RecordingStore: SampleReceiver, @unchecked Sendable {
    let dbPool: DatabasePool

    /// Serializes buffer mutation. `receive` is called on the governor's collection queue,
    /// but flushPending()/catch-up may be invoked from other threads (app termination,
    /// wake handler), so buffer state is confined here rather than to the caller's queue.
    private let queue = DispatchQueue(label: "com.florianriquelme.momo.store.ingest")

    // Buffer state for the in-progress finest (1s) bucket. `INSERT OR REPLACE` is a whole-row
    // replace, so on every flush we recompute the COMPLETE aggregate from `scalarObs`; the
    // last-seen sub-cadence values are carried forward so a partial flush never NULL-wipes a
    // column (U6 sub-cadence partial re-flush scenario).
    private var bucketTs: Int?
    private var scalarObs: [ScalarObservation] = []
    private var procObs: [ProcObservation] = []
    private var tickCount = 0

    /// Minute (1m bucket start) of the most recently flushed 1s bucket. The rollup cascade is
    /// driven event-driven on coarser-boundary completion (KTD2) — it runs only when a flush
    /// crosses into a new minute (a 1m bucket has just sealed), NOT on every 1s flush. Running
    /// the full `catchUp` scan every second is O(rows)/sec and was the U6 smoke-test timeout.
    private var lastFlushedMinute: Int?

    // Clock guard companions (KTD2).
    private var lastWallTs: Int?
    private var lastMono: UInt64?

    /// Monotonic companion clock (mach_continuous_time, advances across sleep). Injectable
    /// for tests.
    private let monoClock: @Sendable () -> UInt64

    // MARK: - Init

    /// Open (or create) the store at `url` in WAL mode with the privacy posture (KTD4b).
    init(url: URL, monoClock: @escaping @Sendable () -> UInt64 = { mach_continuous_time() }) throws {
        self.monoClock = monoClock

        var config = Configuration()
        config.prepareDatabase { db in
            // KTD4b: dropped name bytes are actually overwritten on disk, not left in freed
            // pages / WAL. Set per-connection before any write.
            try db.execute(sql: "PRAGMA secure_delete = ON")
        }
        self.dbPool = try DatabasePool(path: url.path, configuration: config)

        try Schema.makeMigrator().migrate(dbPool)
        try Self.detectTooNewSchema(dbPool)
        try Self.applyFilePrivacy(url: url)
    }

    /// In-memory store for tests (no file privacy / WAL — uses a DatabaseQueue-equivalent
    /// pool path). GRDB requires a real path for a pool; tests pass a temp file via `init`.
    /// This convenience opens a throwaway temp-file pool that is deleted on deinit.
    static func temporary(monoClock: @escaping @Sendable () -> UInt64 = { mach_continuous_time() }) throws -> RecordingStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("momo-test-\(UUID().uuidString).sqlite")
        return try RecordingStore(url: url, monoClock: monoClock)
    }

    // MARK: - SampleReceiver (governor collection queue)

    func receive(_ sample: Sample) {
        let wallTs = Int(sample.timestamp.timeIntervalSince1970)
        let mono = monoClock()
        queue.sync {
            ingestLocked(sample, wallTs: wallTs, mono: mono)
        }
    }

    /// Buffer one tick; flush the sealed bucket on rollover. Must run on `queue`.
    private func ingestLocked(_ sample: Sample, wallTs: Int, mono: UInt64) {
        let decision = ClockGuard.decide(
            lastTs: lastWallTs, sampleTs: wallTs, lastMono: lastMono, sampleMono: mono)

        var effectiveTs = wallTs
        switch decision {
        case .accept:
            break
        case .rejectSlew:
            // Minor NTP slew: fold into the in-progress bucket without rewriting sealed
            // history. Re-bucket the sample at the current bucket's ts.
            effectiveTs = bucketTs ?? wallTs
        case .authoritativeReset:
            // Sustained backward correction: seal the pre-jump tail, then treat the
            // corrected stream as authoritative (overwrite now-incorrect future buckets).
            flushCurrentLocked()
            // Reset companions so subsequent samples key on the corrected stream.
        }

        let tickBucket = bucketStart(effectiveTs, bucketSeconds: Tier.s1.bucketSeconds)

        if let current = bucketTs, current != tickBucket {
            // Rollover: seal & flush the previous bucket, then start the new one.
            flushCurrentLocked()
            resetBuffer(to: tickBucket)
        } else if bucketTs == nil {
            resetBuffer(to: tickBucket)
        }

        scalarObs.append(ScalarObservation(sample))
        procObs.append(contentsOf: ProcObservation.from(sample))
        tickCount += 1

        // Advance clock companions only for accepted-forward samples; a slew keeps the prior
        // companions so a subsequent real-forward sample is judged against the true last ts.
        if decision != .rejectSlew {
            lastWallTs = effectiveTs
            lastMono = mono
        }
    }

    private func resetBuffer(to ts: Int) {
        bucketTs = ts
        scalarObs.removeAll(keepingCapacity: true)
        procObs.removeAll(keepingCapacity: true)
        tickCount = 0
    }

    /// Flush the current buffer to samples_1s, then cascade + prune. Whole-row replace from
    /// the full buffer (carry-forward semantics live in the pure aggregator). No-op on empty.
    private func flushCurrentLocked() {
        guard let ts = bucketTs, tickCount > 0 else { return }
        let scalar = aggregateScalars(ts: ts, scalarObs)
        let procs = aggregateProcs(ts: ts, bucketTickCount: tickCount, procObs)
        let now = lastWallTs ?? ts

        do {
            try dbPool.write { db in
                try RowStore.upsert(scalar, into: Tier.s1.table, db)
                for p in procs {
                    try RowStore.upsert(p, into: Tier.s1.procTable!, db)
                }
            }
            // Cascade is event-driven on coarser-boundary completion (KTD2): only when this
            // flush crosses into a new minute (the prior minute's 1s buckets are all sealed).
            // catchUp then rolls every sealed coarser bucket (handles multi-minute gaps too)
            // and is idempotent, so the once-per-minute cadence loses nothing.
            let minute = bucketStart(ts, bucketSeconds: Tier.m1.bucketSeconds)
            if let last = lastFlushedMinute, minute != last {
                try Rollup.catchUp(dbPool, now: now)
                try checkpoint()
            }
            lastFlushedMinute = minute
        } catch {
            // A write failure must not crash ingest; the next flush re-attempts. (A torn row
            // is impossible — the write is a single transaction.)
        }
    }

    // MARK: - Entry points used by the governor (U5 wires these; we only provide them)

    /// Flush the in-progress bucket synchronously (applicationWillTerminate — durability
    /// bound ≤1 finest bucket on SIGKILL, KTD2).
    func flushPending() {
        queue.sync { flushCurrentLocked() }
    }

    /// Launch/wake catch-up: roll up every completed bucket missed during sleep (KTD4/U6).
    /// Idempotent — a re-run is a no-op. `now` defaults to wall clock.
    func runCatchUp(now: Int = Int(Date().timeIntervalSince1970)) throws {
        try Rollup.catchUp(dbPool, now: now)
        try checkpoint()
    }

    // MARK: - WAL checkpoint (best-effort, tolerates open readers — KTD2)

    private func checkpoint() throws {
        // A blocked checkpoint (open reader) is fine; it retries on the next flush, so the
        // PRAGMA itself is best-effort (`try?`).
        try dbPool.writeWithoutTransaction { db in
            _ = try? db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    // MARK: - Privacy posture (KTD4b)

    /// 0o600 perms on the DB + -wal + -shm; exclude the DB from Time Machine / iCloud.
    private static func applyFilePrivacy(url: URL) throws {
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let p = url.path + suffix
            if fm.fileExists(atPath: p) {
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p)
            }
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
    }

    /// Detect a DB written by a NEWER app version than this binary understands (a migration
    /// we don't have). GRDB's `hasBeenSuperseded` reports this.
    private static func detectTooNewSchema(_ dbPool: DatabasePool) throws {
        let migrator = Schema.makeMigrator()
        let superseded = try dbPool.read { db in
            try migrator.hasBeenSuperseded(db)
        }
        if superseded {
            throw StoreError.databaseTooNew
        }
    }

    enum StoreError: Error { case databaseTooNew }

    // MARK: - Standard on-disk location (KTD4b) — used by the app, not by tests.

    /// `~/Library/Application Support/com.florianriquelme.momo/recording.sqlite`.
    static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("com.florianriquelme.momo", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("recording.sqlite")
    }
}
