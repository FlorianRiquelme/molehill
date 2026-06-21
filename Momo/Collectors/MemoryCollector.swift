//
//  MemoryCollector.swift
//  Memory state collector (R1): used / total bytes, pressure, swap.
//
//  Memory is a point-in-time snapshot, not a rate — no prior-sample state, no delta math, so
//  `reset()` is a no-op. Sources:
//   - total:    `sysctl(HW_MEMSIZE)` (physical RAM, 64-bit).
//   - used:     `host_statistics64(HOST_VM_INFO64)` — "used" is everything that isn't free
//               or speculative, i.e. active + inactive + wired + compressed (the figure
//               Activity Monitor calls "Memory Used"), scaled by the page size.
//   - pressure: `sysctlbyname("kern.memorystatus_vm_pressure_level")` (1 normal / 2 warn /
//               4 critical — the same scale as `MemorySample.Pressure`).
//   - swap:     `sysctl(VM_SWAPUSAGE)` → `xsw_usage.xsu_used`.
//
//  Concurrency (KTD11): a class confined to the governor queue, NOT `Sendable`. Stateless,
//  but a class (not a struct) so it lives uniformly alongside the stateful collectors.
//
import Foundation

/// The raw kernel inputs for a memory reading. Extracted so the byte/pressure math is a pure
/// function tests can drive with fixtures, independent of live `host_*`/`sysctl`.
struct MemoryStats: Equatable {
    let totalBytes: UInt64
    /// Page counts straight from `vm_statistics64`.
    let active: UInt64
    let inactive: UInt64
    let wired: UInt64
    let compressed: UInt64
    let pageSize: UInt64
    /// Raw `kern.memorystatus_vm_pressure_level` (1 / 2 / 4); other values map to `.normal`.
    let pressureLevel: Int32
    let swapUsedBytes: UInt64
}

/// Pure assembly of a `MemorySample` from raw kernel stats — fed fixtures by tests.
enum MemoryMath {
    static func pressure(from level: Int32) -> MemorySample.Pressure {
        MemorySample.Pressure(rawValue: Int(level)) ?? .normal
    }

    static func sample(from s: MemoryStats) -> MemorySample {
        // "Used" = active + inactive + wired + compressed pages × page size. App memory +
        // wired + compressor; matches Activity Monitor's "Memory Used".
        let usedPages = s.active &+ s.inactive &+ s.wired &+ s.compressed
        let usedBytes = usedPages &* s.pageSize
        return MemorySample(
            usedBytes: min(usedBytes, s.totalBytes), // never report more used than installed
            totalBytes: s.totalBytes,
            pressure: pressure(from: s.pressureLevel),
            swapUsedBytes: s.swapUsedBytes
        )
    }
}

final class MemoryCollector: MetricCollector {
    init() {}

    /// No-op: memory has no prior-sample state.
    func reset() {}

    /// Read live kernel stats and assemble a `MemorySample`.
    /// - Throws: `CollectorError.hostCall` / `.sysctl` on a failed kernel call.
    func sample() throws -> MemorySample {
        try MemoryMath.sample(from: Self.readStats())
    }

    static func readStats() throws -> MemoryStats {
        let total = try sysctlUInt64(HW_MEMSIZE, name: "HW_MEMSIZE")
        let vm = try readVMStatistics()
        let pageSize = try readPageSize()
        return MemoryStats(
            totalBytes: total,
            active: UInt64(vm.active_count),
            inactive: UInt64(vm.inactive_count),
            wired: UInt64(vm.wire_count),
            compressed: UInt64(vm.compressor_page_count),
            pageSize: pageSize,
            pressureLevel: (try? readPressureLevel()) ?? 1,
            swapUsedBytes: (try? readSwapUsed()) ?? 0
        )
    }

    private static func readPageSize() throws -> UInt64 {
        var size: vm_size_t = 0
        let kr = host_page_size(mach_host_self(), &size)
        guard kr == KERN_SUCCESS else {
            throw CollectorError.hostCall(api: "host_page_size", code: kr)
        }
        return UInt64(size)
    }

    private static func readVMStatistics() throws -> vm_statistics64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else {
            throw CollectorError.hostCall(api: "host_statistics64", code: kr)
        }
        return stats
    }

    private static func readPressureLevel() throws -> Int32 {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let rc = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        guard rc == 0 else {
            throw CollectorError.sysctl(name: "kern.memorystatus_vm_pressure_level", errno: errno)
        }
        return level
    }

    private static func readSwapUsed() throws -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        var mib: [Int32] = [CTL_VM, VM_SWAPUSAGE]
        let rc = sysctl(&mib, UInt32(mib.count), &usage, &size, nil, 0)
        guard rc == 0 else {
            throw CollectorError.sysctl(name: "VM_SWAPUSAGE", errno: errno)
        }
        return usage.xsu_used
    }

    /// Single-MIB `sysctl` returning a 64-bit value (used for `HW_MEMSIZE`).
    private static func sysctlUInt64(_ id: Int32, name: String) throws -> UInt64 {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        var mib: [Int32] = [CTL_HW, id]
        let rc = sysctl(&mib, UInt32(mib.count), &value, &size, nil, 0)
        guard rc == 0 else {
            throw CollectorError.sysctl(name: name, errno: errno)
        }
        return value
    }
}
