//
//  ProcessAttributionCollector.swift
//  Top-N per-process attribution per subsystem (R6; KTD4a, KTD4b, KTD6, KTD10, KTD11).
//
//  Each tick: enumerate pids (proc_listpids into a reused buffer), read per-pid CPU ticks +
//  memory (proc_pidinfo PROC_PIDTASKINFO) and cumulative disk I/O + phys footprint
//  (proc_pid_rusage RUSAGE_INFO_CURRENT). CPU% and disk rate are DELTAS against cached prior
//  per-pid values; CPU ticks are converted via mach_timebase_info (KTD10 — a no-op on Intel,
//  125/3 on this Apple Silicon machine). A bounded min-selection keeps top-N per subsystem
//  without sorting the full pid list, and the leaf executable name (NEVER the full path —
//  KTD4b) is resolved only for the survivors.
//
//  Per-process attribution covers CPU / memory / disk only — network is system-wide (KTD6).
//
//  Concurrency (KTD11): a class confined to the governor queue, owns prior-sample state for
//  delta math, NOT `Sendable`. Produces the `Sendable` `AttributionSample` / `CorrelatedState`.
//
import Foundation
import AppKit
import os

// MARK: - Pure math (fixture-tested; never touches libproc)

enum ProcMath {
    /// Convert raw mach CPU ticks to nanoseconds via the timebase (KTD10). On Intel the
    /// timebase is 1/1 so this is identity; on Apple Silicon it is 125/3 here.
    static func machToNanos(_ ticks: UInt64, numer: UInt64, denom: UInt64) -> UInt64 {
        guard denom != 0 else { return ticks }
        // Split to limit overflow: (ticks/denom)*numer + (ticks%denom)*numer/denom.
        let whole = (ticks / denom) &* numer
        let rem = (ticks % denom) &* numer / denom
        return whole &+ rem
    }

    /// CPU utilization as a fraction of ONE core over the interval (1.0 == one full core,
    /// matching Activity Monitor's %CPU/100; a multithreaded process can exceed 1.0).
    /// A wrapped/non-monotonic counter or non-positive interval yields 0 — never negative.
    static func cpuFraction(priorNs: UInt64, currentNs: UInt64, wallSeconds: Double) -> Double {
        guard wallSeconds > 0, currentNs >= priorNs else { return 0 }
        return Double(currentNs - priorNs) / (wallSeconds * 1_000_000_000)
    }

    /// Disk I/O rate in bytes/second from cumulative read+write counters. Wrap/non-positive
    /// interval clamps to 0.
    static func diskRate(priorBytes: UInt64, currentBytes: UInt64, wallSeconds: Double) -> Double {
        guard wallSeconds > 0, currentBytes >= priorBytes else { return 0 }
        return Double(currentBytes - priorBytes) / wallSeconds
    }
}

// MARK: - Bounded top-N selection (fixture-tested)

/// Keeps the highest-`value` elements up to `capacity` without sorting the full input — O(n·N)
/// rather than O(n log n). Replaces the current minimum when a larger value arrives.
struct BoundedTopN<Element> {
    private let capacity: Int
    private var items: [(value: Double, element: Element)] = []

    init(capacity: Int) {
        self.capacity = capacity
        items.reserveCapacity(capacity)
    }

    mutating func insert(value: Double, _ element: Element) {
        if items.count < capacity {
            items.append((value, element))
            return
        }
        var minIndex = 0
        for i in 1..<items.count where items[i].value < items[minIndex].value { minIndex = i }
        if value > items[minIndex].value {
            items[minIndex] = (value, element)
        }
    }

    /// Survivors, highest value first.
    func sortedDescending() -> [(value: Double, element: Element)] {
        items.sorted { $0.value > $1.value }
    }
}

// MARK: - Foreground-app tracking (R6 correlated state)

/// Caches the frontmost app's name from `didActivateApplicationNotification` (observed on the
/// main thread) and exposes it thread-safely so the governor-queue-confined collector can read
/// it without touching `NSWorkspace` off-main. Started once from the app delegate (U5).
final class ForegroundAppTracker: NSObject, @unchecked Sendable {
    static let shared = ForegroundAppTracker()
    private let state = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// Latest frontmost-app name (leaf, localized). Safe to read from any thread.
    var current: String? { state.withLock { $0 } }

    /// Begin observing. Must be called on the main actor (touches `NSWorkspace`).
    @MainActor func start() {
        state.withLock { $0 = NSWorkspace.shared.frontmostApplication?.localizedName }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    @objc private func activated(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        state.withLock { $0 = app?.localizedName }
    }
}

// MARK: - Collector

final class ProcessAttributionCollector: MetricCollector {
    /// Top processes retained per subsystem per tick.
    static let topN = 5

    private struct Prior { let cpuNs: UInt64; let diskBytes: UInt64 }
    private struct Candidate { let pid: pid_t; let restricted: Bool }

    private var prior: [pid_t: Prior] = [:]
    private var priorTimestamp: Date?
    private var pidBuffer: [pid_t]
    private let timebaseNumer: UInt64
    private let timebaseDenom: UInt64
    private let foregroundProvider: @Sendable () -> String?

    /// - Parameter foregroundProvider: source of the frontmost-app name; defaults to the
    ///   shared `ForegroundAppTracker`. Injected in tests.
    /// - Throws: `CollectorError.malformedReply` if a pinned libproc struct stride has drifted
    ///   from its known-good baseline (KTD5 layout guard) — we refuse to record corrupt
    ///   attribution rather than store 30 days of it.
    init(foregroundProvider: @escaping @Sendable () -> String? = { ForegroundAppTracker.shared.current }) throws {
        #if arch(arm64)
        // Baselines measured on arm64 (macOS 26). Intel layout is unverified (OQ9, best-effort)
        // so the static guard is arm64-only; the per-call size check below covers both arches.
        guard MemoryLayout<proc_taskinfo>.size == 96,
              MemoryLayout<rusage_info_current>.size == 464 else {
            throw CollectorError.malformedReply(
                detail: "libproc struct stride drift: proc_taskinfo=\(MemoryLayout<proc_taskinfo>.size) rusage_info_current=\(MemoryLayout<rusage_info_current>.size)")
        }
        #endif
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        timebaseNumer = UInt64(tb.numer)
        timebaseDenom = UInt64(tb.denom)
        pidBuffer = [pid_t](repeating: 0, count: 4096)
        self.foregroundProvider = foregroundProvider
    }

    func reset() {
        prior.removeAll(keepingCapacity: true)
        priorTimestamp = nil
    }

    /// Foreground app + power at sample time (R6). Power is injected by the governor from its
    /// `PowerContext` snapshot (KTD11) — the collector does not own power observation.
    func correlatedState(power: PowerSnapshot) -> CorrelatedState {
        CorrelatedState(foregroundApp: foregroundProvider(), power: power)
    }

    /// Enumerate processes and produce top-N attribution per subsystem at `now`.
    func sample(at now: Date) throws -> AttributionSample {
        let pids = try Self.listPIDs(into: &pidBuffer)
        let wallSeconds = priorTimestamp.map { now.timeIntervalSince($0) } ?? 0
        let hasPrior = wallSeconds > 0

        var cpuTop = BoundedTopN<Candidate>(capacity: Self.topN)
        var memTop = BoundedTopN<Candidate>(capacity: Self.topN)
        var diskTop = BoundedTopN<Candidate>(capacity: Self.topN)
        var newPrior: [pid_t: Prior] = Dictionary(minimumCapacity: pids.count)

        for pid in pids where pid > 0 {
            // CPU ticks + resident memory. Failure => pid exited or is unreadable; skip it
            // (we cannot rank what we cannot measure — an honest non-privileged limitation).
            guard let ti = Self.taskInfo(pid) else { continue }
            let cpuNs = ProcMath.machToNanos(ti.pti_total_user &+ ti.pti_total_system,
                                             numer: timebaseNumer, denom: timebaseDenom)

            // Disk I/O + phys footprint. EPERM here (e.g. root-owned) => restricted: we keep
            // CPU/memory rows with the flag but cannot attribute disk for this process.
            let ru = Self.rusage(pid)
            let restricted = (ru == nil)
            let footprint = ru?.ri_phys_footprint ?? UInt64(ti.pti_resident_size)
            let diskBytes = ru.map { $0.ri_diskio_bytesread &+ $0.ri_diskio_byteswritten }

            newPrior[pid] = Prior(cpuNs: cpuNs, diskBytes: diskBytes ?? 0)
            let candidate = Candidate(pid: pid, restricted: restricted)

            // Memory is instantaneous.
            memTop.insert(value: Double(footprint), candidate)

            // CPU + disk are deltas: a freshly-seen pid (no prior) contributes 0 this tick.
            if hasPrior, let p = prior[pid] {
                let cpu = ProcMath.cpuFraction(priorNs: p.cpuNs, currentNs: cpuNs, wallSeconds: wallSeconds)
                if cpu > 0 { cpuTop.insert(value: cpu, candidate) }
                if let diskBytes {
                    let rate = ProcMath.diskRate(priorBytes: p.diskBytes, currentBytes: diskBytes, wallSeconds: wallSeconds)
                    if rate > 0 { diskTop.insert(value: rate, candidate) }
                }
            }
        }

        prior = newPrior
        priorTimestamp = now

        let cpuRows = cpuTop.sortedDescending()
        let memRows = memTop.sortedDescending()
        let diskRows = diskTop.sortedDescending()

        // Resolve leaf names only for survivors (KTD4b), once per pid across subsystems.
        var names: [pid_t: String] = [:]
        for row in cpuRows + memRows + diskRows where names[row.element.pid] == nil {
            names[row.element.pid] = Self.procName(row.element.pid) ?? "pid \(row.element.pid)"
        }

        func attribution(_ rows: [(value: Double, element: Candidate)], _ subsystem: Subsystem) -> [ProcessAttribution] {
            rows.map { row in
                ProcessAttribution(pid: row.element.pid,
                                   name: names[row.element.pid] ?? "pid \(row.element.pid)",
                                   subsystem: subsystem,
                                   value: row.value,
                                   restricted: row.element.restricted)
            }
        }

        return AttributionSample(bySubsystem: [
            .cpu: attribution(cpuRows, .cpu),
            .memory: attribution(memRows, .memory),
            .disk: attribution(diskRows, .disk),
        ])
    }

    // MARK: libproc wrappers

    /// Enumerate all pids into the reused buffer, growing it if needed. Returns the populated
    /// prefix.
    static func listPIDs(into buffer: inout [pid_t]) throws -> ArraySlice<pid_t> {
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { throw CollectorError.libproc(api: "proc_listpids(size)", errno: errno) }
        let count = Int(needed) / MemoryLayout<pid_t>.size
        if buffer.count < count { buffer = [pid_t](repeating: 0, count: count + 64) }
        let written = buffer.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count))
        }
        guard written > 0 else { throw CollectorError.libproc(api: "proc_listpids", errno: errno) }
        return buffer[0..<(Int(written) / MemoryLayout<pid_t>.size)]
    }

    /// PROC_PIDTASKINFO for one pid. Returns nil on EPERM/exited/short-read — the per-call size
    /// check is the dynamic half of the KTD5 layout guard (kernel-vs-SDK disagreement).
    static func taskInfo(_ pid: pid_t) -> proc_taskinfo? {
        var ti = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let r = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, size)
        guard r == size else { return nil }
        return ti
    }

    /// RUSAGE_INFO_CURRENT for one pid. Returns nil on EPERM/exited.
    static func rusage(_ pid: pid_t) -> rusage_info_current? {
        var ru = rusage_info_current()
        let r = withUnsafeMutablePointer(to: &ru) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
            }
        }
        return r == 0 ? ru : nil
    }

    /// Leaf executable name only (KTD4b) — `proc_name`, never `proc_pidpath`.
    static func procName(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        let n = proc_name(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }
}
