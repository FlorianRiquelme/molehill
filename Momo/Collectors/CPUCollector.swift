//
//  CPUCollector.swift
//  CPU utilization collector (R1): overall + per-core fractions in 0...1.
//
//  Source: `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` returns cumulative tick counters
//  per logical core (user / system / nice / idle). Utilization is a DELTA between two
//  snapshots — busy ticks ÷ total ticks over the interval (KTD11 delta-of-cumulative).
//  The returned array is kernel-owned and must be `vm_deallocate`d.
//
//  Concurrency (KTD11): a class confined to the governor queue, owns the prior snapshot for
//  delta math, NOT `Sendable`. Produces a `Sendable` `CPUSample`.
//
import Foundation

/// One core's cumulative CPU tick counters (the four `CPU_STATE_*` buckets), summed since
/// boot. The unit (HZ) cancels out in the ratio, so we never convert to time.
struct CPUTicks: Equatable {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32

    /// Ticks spent doing work this interval (everything that isn't idle).
    var busy: UInt32 { user &+ system &+ nice }
    /// All ticks this interval.
    var total: UInt32 { user &+ system &+ nice &+ idle }
}

/// Pure delta math for CPU utilization — fed fixtures by tests, never touches `host_*`.
enum CPUMath {
    /// Per-core utilization from two cumulative snapshots, as fractions in 0...1.
    ///
    /// Counter semantics: these are monotonic per-core tick totals. A core that was offline
    /// and came back, or a counter that wrapped (32-bit), yields a non-monotonic diff; we
    /// clamp such a core to 0 rather than emitting a negative/absurd fraction (wrap handling).
    /// A core whose total didn't advance (idle-since-last, or freshly onlined) is 0, not NaN.
    ///
    /// - Parameter prior/current: equal-length arrays, one entry per logical core. Callers
    ///   that observe a core-count change between snapshots must treat it as a fresh sample
    ///   (return nil from the live path) — this function requires matching lengths.
    static func perCore(prior: [CPUTicks], current: [CPUTicks]) -> [Double] {
        precondition(prior.count == current.count, "core count changed between snapshots")
        return zip(prior, current).map { p, c in
            // Wrapped/non-monotonic counter (e.g. core offlined): treat as no usable delta.
            guard c.total >= p.total, c.busy >= p.busy else { return 0 }
            let totalDelta = c.total &- p.total
            guard totalDelta > 0 else { return 0 }
            let busyDelta = c.busy &- p.busy
            return min(1.0, Double(busyDelta) / Double(totalDelta))
        }
    }

    /// Overall utilization: busy-ticks summed across all cores ÷ total-ticks summed across
    /// all cores (aggregate ratio, not the mean of per-core fractions — these coincide only
    /// when every core advanced equally). Clamps wrap per core so a glitching core can't drag
    /// the aggregate negative.
    static func overall(prior: [CPUTicks], current: [CPUTicks]) -> Double {
        precondition(prior.count == current.count, "core count changed between snapshots")
        var busySum: UInt64 = 0
        var totalSum: UInt64 = 0
        for (p, c) in zip(prior, current) {
            guard c.total >= p.total, c.busy >= p.busy else { continue }
            busySum &+= UInt64(c.busy &- p.busy)
            totalSum &+= UInt64(c.total &- p.total)
        }
        guard totalSum > 0 else { return 0 }
        return min(1.0, Double(busySum) / Double(totalSum))
    }
}

final class CPUCollector: MetricCollector {
    private var prior: [CPUTicks]?

    init() {}

    func reset() { prior = nil }

    /// Read the live per-core tick snapshot, diff against the prior, and produce a
    /// `CPUSample`. The first call after init/reset has no prior → returns a fresh-sample
    /// reading (zeroes), never a startup spike. A core-count change vs. the prior snapshot is
    /// also treated as fresh (we re-baseline rather than index across mismatched arrays).
    /// - Throws: `CollectorError.hostCall` if `host_processor_info` fails.
    func sample() throws -> CPUSample {
        let current = try Self.readTicks()
        defer { prior = current }

        guard let prior, prior.count == current.count else {
            // Fresh sample (first tick, post-reset, or core count changed): no usable delta.
            return CPUSample(overall: 0, perCore: Array(repeating: 0, count: current.count))
        }
        return CPUSample(
            overall: CPUMath.overall(prior: prior, current: current),
            perCore: CPUMath.perCore(prior: prior, current: current)
        )
    }

    /// Thin wrapper over `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`. Copies the
    /// kernel-owned array into Swift values and `vm_deallocate`s the original.
    static func readTicks() throws -> [CPUTicks] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let kr = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &info,
            &infoCount
        )
        guard kr == KERN_SUCCESS, let info else {
            throw CollectorError.hostCall(api: "host_processor_info", code: kr)
        }
        // Always release the kernel allocation, success path included.
        defer {
            let size = vm_size_t(UInt(infoCount) * UInt(MemoryLayout<integer_t>.stride))
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), size)
        }

        let stride = Int(CPU_STATE_MAX) // 4 integer_t per core
        var ticks: [CPUTicks] = []
        ticks.reserveCapacity(Int(cpuCount))
        for core in 0..<Int(cpuCount) {
            let base = core * stride
            ticks.append(CPUTicks(
                user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            ))
        }
        return ticks
    }
}
