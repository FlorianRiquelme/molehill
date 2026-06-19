//
//  Rollup.swift
//  Cascade (1s->1m->1h), retention prune, launch/wake catch-up, clock-monotonicity guard
//  (KTD2 / KTD4 / KTD4a). Each cascade level is ONE write transaction on the single
//  DatabasePool writer; a finer row is pruned only by retention AGE (not "already rolled
//  up"), so catch-up is idempotent and a re-run is a no-op.
//
//  Most of the correctness-critical math is in pure functions in Rows.swift; this file is
//  the transaction-shaped glue plus the clock guard.
//
import Foundation
import GRDB

enum Rollup {
    /// Bound on rows deleted per prune transaction, to keep WAL growth bounded (KTD2/U6).
    static let pruneBatchLimit = 10_000

    // MARK: - Cascade

    /// Cascade all sealed finer buckets up one level for `tier` -> `tier.nextCoarser`,
    /// then prune by retention. `now` is the current wall clock (UTC epoch seconds): it
    /// defines the retention horizon and which finer buckets are "sealed".
    ///
    /// Sealed = a finer bucket strictly older than the finer bucket containing `now`
    /// (the in-progress finest bucket is never rolled up — KTD4). Each coarser bucket is
    /// (re)written with INSERT OR REPLACE, so re-running over already-rolled data produces
    /// identical rows (no-op). Returns the coarser buckets touched (for tests).
    @discardableResult
    static func cascade(_ db: Database, from tier: Tier, now: Int) throws -> [Int] {
        guard let coarser = tier.nextCoarser else { return [] }
        let fineW = tier.bucketSeconds
        let coarseW = coarser.bucketSeconds

        // The finest in-progress bucket must be excluded. "Sealed" cutoff: any finer row
        // with ts < sealCutoff is in a closed finer bucket.
        let sealCutoff = bucketStart(now, bucketSeconds: fineW)

        // Which coarser buckets have sealed finer source rows? A coarser bucket is eligible
        // only when its ENTIRE window is sealed (every finer sub-bucket within it is closed),
        // so a coarser aggregate is never computed over a partial finer bucket.
        let candidateCoarseStarts = try coarseBucketStarts(
            db, finerTable: tier.table, coarseWidth: coarseW,
            upTo: sealCutoff)

        var touched: [Int] = []
        for cstart in candidateCoarseStarts {
            let cend = cstart + coarseW
            // Eligible only if the whole coarse window is sealed (every finer sub-bucket
            // within [cstart, cend) is closed). The finest in-progress bucket lives at
            // ts >= sealCutoff, so requiring cend <= sealCutoff excludes any open window.
            if cend > sealCutoff { continue }

            let finerScalars = try RowStore.scalars(in: tier.table, from: cstart, to: cend, db)
            guard !finerScalars.isEmpty else { continue }

            let dropFg = (coarser == .h1)   // foreground app ages out at 1h (KTD4)
            let scalar = rollupScalars(ts: cstart, finerScalars, dropForeground: dropFg)
            try RowStore.upsert(scalar, into: coarser.table, db)

            // Per-process: names kept at 1m, dropped at 1h (no proc_1h table — KTD4).
            if let coarseProc = coarser.procTable, let finerProc = tier.procTable {
                try rollupProcs(db,
                    finerProcTable: finerProc, coarseProcTable: coarseProc,
                    from: cstart, to: cend, coarseStart: cstart,
                    finerWidth: fineW)
            }
            touched.append(cstart)
        }

        try prune(db, tier: tier, now: now)
        return touched
    }

    /// Distinct aligned coarse-bucket starts that have at least one finer row whose own
    /// bucket is sealed (ts < upTo).
    private static func coarseBucketStarts(
        _ db: Database, finerTable: String, coarseWidth: Int, upTo: Int
    ) throws -> [Int] {
        let tss = try Int.fetchAll(db,
            sql: "SELECT DISTINCT ts FROM \(finerTable) WHERE ts < ? ORDER BY ts",
            arguments: [upTo])
        var starts: [Int] = []
        var seen = Set<Int>()
        for ts in tss {
            let cs = bucketStart(ts, bucketSeconds: coarseWidth)
            if seen.insert(cs).inserted { starts.append(cs) }
        }
        return starts
    }

    /// Roll finer per-process rows in [lo,hi) into one coarse bucket (KTD4a). The full-bucket
    /// denominator is the coarse window's tick count (coarseWidth / finerWidth), so a process
    /// present in only some finer buckets is correctly diluted.
    private static func rollupProcs(
        _ db: Database,
        finerProcTable: String, coarseProcTable: String,
        from lo: Int, to hi: Int, coarseStart: Int, finerWidth: Int
    ) throws {
        let finerRows = try RowStore.procs(in: finerProcTable, from: lo, to: hi, db)
        guard !finerRows.isEmpty else { return }

        let subBuckets = (hi - lo) / finerWidth   // e.g. 60 finer buckets per coarse bucket

        // Coarse `value` = unweighted mean of the finer averages over the FULL coarse window
        // (denominator = number of finer sub-buckets, KTD4a full-bucket denominator), so a
        // process present in only some finer buckets is correctly diluted. For full buckets
        // this equals the tick-weighted mean; partial finer buckets differ only to rounding,
        // matching the scalar rollup policy. `value_max` = max of the finer `value_max`.
        //
        // KNOWN LIMITATION (see Residual Review Findings): per-process attribution runs on a
        // slower sub-cadence than the scalar metrics (KTD3), so at detail cadence only ~1/N of
        // the finer sub-buckets carry proc rows. Dividing by the full `subBuckets` count
        // therefore deflates a sustained process's `value` by the sub-cadence factor N. The
        // ranking is preserved (uniform scaling) and `value_max` is exact; the correct fix
        // (dividing by the attribution-sample count) needs that count recorded per bucket and is
        // deferred so the irreversible schema decision isn't rushed.
        struct Key: Hashable { let subsystem: String; let pid: Int64; let name: String }
        var sums: [Key: Double] = [:]
        var peaks: [Key: Double] = [:]
        for r in finerRows {
            let k = Key(subsystem: r.subsystem, pid: r.pid, name: r.name)
            sums[k, default: 0] += r.value
            peaks[k] = Swift.max(peaks[k] ?? -.infinity, r.valueMax)
        }

        var bySubsystem: [String: [ProcRow]] = [:]
        for (k, sum) in sums {
            let row = ProcRow(
                ts: coarseStart, subsystem: k.subsystem, pid: k.pid, name: k.name,
                value: sum / Double(subBuckets), valueMax: peaks[k] ?? 0)
            bySubsystem[k.subsystem, default: []].append(row)
        }
        for (_, rows) in bySubsystem {
            for row in selectSurvivors(rows, topN: perBucketTopN) {
                try RowStore.upsert(row, into: coarseProcTable, db)
            }
        }
    }

    // MARK: - Retention prune (age-driven, batched)

    /// Delete rows older than `tier.retentionSeconds` relative to `now`, in bounded
    /// ts-range batches (KTD2/U6 WAL bound). Idempotent — a re-run with no aged rows is a
    /// no-op. Returns total rows deleted (scalar table).
    @discardableResult
    static func prune(_ db: Database, tier: Tier, now: Int) throws -> Int {
        let horizon = now - tier.retentionSeconds
        var totalDeleted = 0
        var lastUpper = Int.min
        while true {
            // Find a bounded ts ceiling: the pruneBatchLimit-th oldest ts below horizon.
            let batchTss = try Int.fetchAll(db,
                sql: "SELECT ts FROM \(tier.table) WHERE ts < ? ORDER BY ts LIMIT ?",
                arguments: [horizon, pruneBatchLimit])
            guard let lastTs = batchTss.last else { break }
            let upper = lastTs + 1   // inclusive of lastTs
            // Zero-progress guard: each batch must advance the deleted ceiling. If a DELETE
            // is silently no-op'd (constraint/trigger), `upper` wouldn't move — break rather
            // than loop forever holding the writer lock.
            guard upper > lastUpper else { break }
            lastUpper = upper

            try db.execute(
                sql: "DELETE FROM \(tier.table) WHERE ts < ?", arguments: [upper])
            if let proc = tier.procTable {
                try db.execute(
                    sql: "DELETE FROM \(proc) WHERE ts < ?", arguments: [upper])
            }
            totalDeleted += batchTss.count
            if batchTss.count < pruneBatchLimit { break }
        }
        return totalDeleted
    }

    // MARK: - Catch-up (launch / wake)

    /// Roll up every completed coarser bucket across all tiers, then prune (KTD4 / U6
    /// catch-up). Safe to run repeatedly: idempotent. Each cascade level is its own
    /// transaction so a crash between levels loses nothing (re-run completes it).
    static func catchUp(_ dbPool: DatabasePool, now: Int) throws {
        for tier in [Tier.s1, Tier.m1] {
            try dbPool.write { db in
                _ = try cascade(db, from: tier, now: now)
            }
        }
        // Prune the coarsest tier by age (it is never a cascade source).
        try dbPool.write { db in
            _ = try prune(db, tier: .h1, now: now)
        }
    }
}

// MARK: - Clock-monotonicity guard (KTD2)

/// Distinguishes NTP slew (small backward step) from a stale-RTC / manual-set jump
/// (sustained backward correction), using a monotonic companion clock. Pure decision logic;
/// the actual wall-clock & mach reads are injected so it is unit-testable (KTD2/U6).
enum ClockGuard {
    /// Slew threshold: a backward step within one *coarser* bucket (1m) is treated as a
    /// minor NTP slew (corrections are sub-minute) and folded without rewriting sealed
    /// history; a step of a full minute or more is a sustained correction (stale RTC / manual
    /// set) and is authoritative. (Using the 1m bucket, not the 1s finest bucket, because at
    /// 1s granularity a sub-second slew floors to the same ts and never even reaches here.)
    static let slewThresholdSeconds = Tier.m1.bucketSeconds

    enum Decision: Equatable {
        /// Normal forward (or first) sample — accept and bucket at `ts`.
        case accept
        /// Small backward step (< one bucket): re-bucket into the last sealed bucket without
        /// overwriting sealed history — i.e. fold into the in-progress bucket, never rewrite
        /// an already-sealed earlier one.
        case rejectSlew
        /// Sustained backward correction: the corrected stream is authoritative. Seal the
        /// pre-jump tail and accept `ts`, overwriting now-incorrect future-dated buckets.
        case authoritativeReset
    }

    /// - lastTs: the most recent accepted wall `ts` (nil before first sample).
    /// - sampleTs: this sample's wall `ts`.
    /// - lastMono / sampleMono: the monotonic companion readings (mach_continuous_time
    ///   nanoseconds) at those two samples. The monotonic delta is the true elapsed time;
    ///   if wall went backward but mono advanced ~normally, it's a clock correction.
    static func decide(
        lastTs: Int?, sampleTs: Int,
        lastMono: UInt64?, sampleMono: UInt64
    ) -> Decision {
        // `lastMono` non-nil marks "we have a prior sample"; its value isn't compared (see below).
        guard let lastTs, lastMono != nil else { return .accept }
        if sampleTs >= lastTs { return .accept }   // forward or same — normal

        let backwardBy = lastTs - sampleTs
        if backwardBy < slewThresholdSeconds {
            return .rejectSlew
        }
        // Backward by >= one bucket. The monotonic companion would confirm real time kept
        // advancing (a wall-clock correction, not a replay), but the decision is the same
        // either way: the corrected wall stream is authoritative — the wall clock is what we
        // bucket on (KTD2). The mono direction is intentionally not branched here.
        return .authoritativeReset
    }
}
