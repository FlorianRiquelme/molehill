//
//  HistoryQuery.swift
//  Historical query layer — tier selection by zoom + explicit gap surfacing (U9).
//
//  Reads the recorded tiers (Store/) for an arbitrary [start, end] window, picking the
//  resolution that matches the requested zoom so the chart receives a few hundred points
//  rather than raw history, and surfaces gaps EXPLICITLY so the UI renders a break instead
//  of interpolating across missing time. This is the Phase-2 foundation for R8 (scrub-back)
//  and R9 (causal drill-down).
//
//  Invariants this layer upholds (from the U6 "Phase 1 schema must satisfy Phase 2 reads"
//  checklist):
//    * Tier selection picks exactly ONE tier per query, so a window straddling the 48h/30d
//      seam never double-counts overlapping buckets (KTD2 / no-double-count).
//    * A GAP is the ABSENCE of rows in the chosen tier across a ts sub-range — distinct from
//      a present row carrying a NULL metric, which means "sensor absent" (KTD2 / U6 / R12).
//      Gaps are surfaced as explicit `.gap` points; a present row is a `.sample` point even
//      when every metric is NULL. The chart therefore breaks across a sleep gap but plots a
//      recorded row with missing sensors.
//    * Both the AVG and the MAX series are carried for every gauge metric so the UI can
//      surface spikes that averaging would hide at the coarse tiers (KTD4 / KTD12).
//
//  Concurrency (Swift 6 strict): all reads go through GRDB's concurrent reader pool
//  (`dbPool.read` / `ValueObservation`), never the writer — a query can never block ingest
//  and a long-held read snapshot (a parked scrubber) is a consistent WAL snapshot, not a
//  `SQLITE_BUSY`. `HistorySeries` and its parts are immutable `Sendable` value types.
//
import Foundation
import GRDB

// MARK: - Result types

/// One queried point. A `.sample` carries the bucket's scalar aggregates (AVG+MAX); a `.gap`
/// marks a sub-range of the chosen tier that has NO rows, so the chart renders a break rather
/// than interpolating (KTD2/U6). The gap's `from`/`to` are aligned bucket starts (UTC seconds).
enum HistoryPoint: Sendable, Equatable {
    case sample(ScalarRow)
    case gap(from: Int, to: Int)
}

/// The result of a point-in-time history query over `[start, end]`.
struct HistorySeries: Sendable, Equatable {
    /// The tier the query resolved to (one tier for the whole window — no seam double-count).
    let tier: Tier
    /// The window actually served, after clamping to retained data (`resolvedStart` may be
    /// later than the requested start — see `truncatedToOldest`).
    let resolvedStart: Int
    let resolvedEnd: Int
    /// True when the requested window reached earlier than the oldest retained row in the
    /// chosen tier and was clamped forward to it (the UI should indicate the truncation).
    let truncatedToOldest: Bool
    /// Points in ascending `ts` order, with `.gap` markers interleaved where rows are absent.
    let points: [HistoryPoint]

    /// Scalar rows only (gaps elided) — convenience for callers that just want the series.
    var rows: [ScalarRow] {
        points.compactMap { if case .sample(let r) = $0 { return r } else { return nil } }
    }
}

// MARK: - Pure tier selection (testable without a DB)

enum HistoryQueryPlan {
    /// Choose the resolution for a `[start, end)` window against a target point budget.
    ///
    /// Rule (KTD4 / U9): pick the FINEST tier whose bucket count over the window is within
    /// budget — maximum resolution the chart can afford. If even the coarsest tier exceeds
    /// the budget (a very wide window), fall back to the coarsest tier (1h). A tier is never
    /// chosen finer than the data retained for the window's age: when `now` is supplied, a
    /// tier whose retention horizon does not reach back to `start` is skipped, so a months-old
    /// window can't select the 1s tier whose rows were pruned at 48h.
    ///
    /// Examples (budget 500): a 6-hour window → 1m (1s=21600>budget, 1m=360≤budget); a
    /// 6-month window → 1h (every tier exceeds budget → coarsest).
    static func selectTier(start: Int, end: Int, budget: Int, now: Int? = nil) -> Tier {
        let span = max(0, end - start)
        // Finest → coarsest. Pick the first that both fits the budget and is retained.
        for tier in [Tier.s1, .m1, .h1] {
            if let now, !retains(tier, start: start, now: now) { continue }
            let buckets = bucketCount(span: span, bucketSeconds: tier.bucketSeconds)
            if buckets <= budget { return tier }
        }
        // No tier fits the budget → coarsest available resolution.
        return .h1
    }

    /// Number of aligned buckets a span of `span` seconds spans at `bucketSeconds`.
    static func bucketCount(span: Int, bucketSeconds: Int) -> Int {
        guard span > 0 else { return 0 }
        // Round up — a partial trailing bucket still counts as one point.
        return (span + bucketSeconds - 1) / bucketSeconds
    }

    /// Whether `tier` still retains data back to `start` given `now` (KTD4 retention horizon).
    private static func retains(_ tier: Tier, start: Int, now: Int) -> Bool {
        start >= now - tier.retentionSeconds
    }
}

// MARK: - Query

/// Reads `HistorySeries` from a `DatabasePool` (the store's reader pool). Holds only the pool,
/// not the `RecordingStore` — so it never touches the writer and a new `RecordingStore` read
/// entry point is unnecessary (see report note). Construct with `store.dbPool`.
struct HistoryQuery: Sendable {
    let dbPool: DatabasePool
    /// Target number of points returned (a "few hundred" — KTD/U9). Wide windows fall to a
    /// coarser tier; very wide windows return the coarsest tier even above this.
    let budget: Int

    init(dbPool: DatabasePool, budget: Int = 500) {
        self.dbPool = dbPool
        self.budget = budget
    }

    /// Point-in-time query: select the tier, fetch the rows on the reader pool, clamp to the
    /// oldest retained row, and interleave explicit gap markers. `now` (defaults to wall clock)
    /// gates tier selection by retention so an old window can't pick a pruned-away fine tier.
    func series(start: Int, end: Int, now: Int = Int(Date().timeIntervalSince1970)) throws -> HistorySeries {
        let tier = HistoryQueryPlan.selectTier(start: start, end: end, budget: budget, now: now)
        return try dbPool.read { db in
            try Self.buildSeries(tier: tier, start: start, end: end, db)
        }
    }

    /// Observe the query as a `ValueObservation` so a view live-updates as new rollups land
    /// (U9 plus / GRDB `ValueObservation`). The tier is fixed at observation-creation time
    /// from the requested window; the observed value re-fetches whenever the chosen tier's
    /// table changes. Reads run on the reader pool — ingest is never blocked.
    func observe(start: Int, end: Int, now: Int = Int(Date().timeIntervalSince1970))
        -> ValueObservation<ValueReducers.Fetch<HistorySeries>>
    {
        let tier = HistoryQueryPlan.selectTier(start: start, end: end, budget: budget, now: now)
        return ValueObservation.tracking { db in
            try Self.buildSeries(tier: tier, start: start, end: end, db)
        }
    }

    // MARK: - Row → series assembly (runs inside a read transaction)

    /// Fetch the chosen tier's rows in `[start, end)`, clamp to the oldest retained row, and
    /// interleave `.gap` markers for absent bucket ranges. Aligned to the tier's bucket width
    /// so the seam math and gap boundaries are exact (KTD2).
    static func buildSeries(tier: Tier, start: Int, end: Int, _ db: Database) throws -> HistorySeries {
        let step = tier.bucketSeconds
        // Align the requested window to the tier's bucket grid so gap boundaries land on
        // bucket starts and the half-open range covers the trailing partial bucket.
        let alignedStart = bucketStart(start, bucketSeconds: step)
        let alignedEnd = bucketStart(max(start, end - 1), bucketSeconds: step) + step

        let rows = try RowStore.scalars(in: tier.table, from: alignedStart, to: alignedEnd, db)

        // Clamp: if the window reaches earlier than the oldest retained row, serve from the
        // oldest row and flag truncation (KTD4 retention / U9 clamp). With no rows at all the
        // window is empty — report it as a single gap over the whole aligned window.
        guard let firstTs = rows.first?.ts else {
            return HistorySeries(
                tier: tier,
                resolvedStart: alignedStart,
                resolvedEnd: alignedEnd,
                truncatedToOldest: false,
                points: [.gap(from: alignedStart, to: alignedEnd)])
        }
        let truncated = firstTs > alignedStart
        let resolvedStart = truncated ? firstTs : alignedStart

        // Interleave gaps: a gap is any aligned bucket range inside the resolved window that
        // carries no row. Walk the sorted rows, emitting a `.gap` whenever the next row ts is
        // more than one bucket past the cursor (KTD2/U6 gap = absence of rows). A NULL metric
        // inside a present row is NOT a gap — it stays a `.sample`.
        var points: [HistoryPoint] = []
        var cursor = resolvedStart
        for row in rows {
            if row.ts > cursor {
                points.append(.gap(from: cursor, to: row.ts))
            }
            points.append(.sample(row))
            cursor = row.ts + step
        }
        // Trailing gap from the last row to the resolved end of the window.
        if cursor < alignedEnd {
            points.append(.gap(from: cursor, to: alignedEnd))
        }

        return HistorySeries(
            tier: tier,
            resolvedStart: resolvedStart,
            resolvedEnd: alignedEnd,
            truncatedToOldest: truncated,
            points: points)
    }
}
