//
//  DiskCollector.swift
//  Disk usage + I/O throughput collector (R1).
//
//  Two independent readings composed into one `DiskSample`:
//   - Usage (free / total bytes): `URL.resourceValues` on the boot volume, using
//     `.volumeAvailableCapacityForImportantUsageKey` (the figure Finder/Activity Monitor
//     show — accounts for purgeable space) and `.volumeTotalCapacityKey`. Point-in-time.
//   - Throughput (read/write bytes/sec): IOKit `IOBlockStorageDriver` services expose a
//     `Statistics` dict with cumulative `Bytes (Read)` / `Bytes (Write)` 64-bit counters,
//     summed across all block-storage drivers and DIFFED between samples over the interval.
//
//  Concurrency (KTD11): a class confined to the governor queue, owns the prior I/O counter
//  snapshot for the rate delta, NOT `Sendable`. Produces a `Sendable` `DiskSample`.
//
import Foundation
import IOKit

/// Cumulative byte counters for the rate delta, captured with the instant they were read.
struct IOCounters: Equatable {
    var readBytes: UInt64
    var writeBytes: UInt64
    var timestamp: Date
}

/// Pure delta-of-cumulative-counters rate math, shared by disk and network.
/// Input: two cumulative snapshots + their timestamps → bytes/second. Tests drive this with
/// fixtures; the live syscall/IOKit wrappers stay thin.
enum RateMath {
    /// Bytes/second between two cumulative readings.
    ///
    /// Counter-wrap / non-monotonic handling: a 64-bit counter that wrapped, or a device that
    /// disappeared and reset, makes `current < prior`. We clamp that channel to 0 rather than
    /// emit a negative or absurd rate (KTD11 wrap handling). A zero or negative interval
    /// (clock skew, duplicate timestamp) also yields 0 — never a divide-by-zero or spike.
    static func bytesPerSecond(priorBytes: UInt64, currentBytes: UInt64, interval: TimeInterval) -> Double {
        guard interval > 0 else { return 0 }
        guard currentBytes >= priorBytes else { return 0 } // wrap / reset → clamp
        let delta = currentBytes &- priorBytes
        return Double(delta) / interval
    }
}

final class DiskCollector: MetricCollector {
    // IOBlockStorageDriver property keys. The C `#define`s in IOBlockStorageDriver.h are not
    // exported to Swift, so the string values are pinned here.
    private static let statisticsKey = "Statistics"
    private static let bytesReadKey = "Bytes (Read)"
    private static let bytesWrittenKey = "Bytes (Write)"

    private let bootVolume: URL
    private var priorIO: IOCounters?

    /// - Parameter bootVolume: the volume to report usage for; defaults to `/`.
    init(bootVolume: URL = URL(fileURLWithPath: "/")) {
        self.bootVolume = bootVolume
    }

    func reset() { priorIO = nil }

    /// Read usage + cumulative I/O counters, diff the counters against the prior snapshot, and
    /// produce a `DiskSample`. First call after init/reset has no prior counter snapshot →
    /// zero-rate (never a spike), but usage is still reported.
    /// - Throws: `CollectorError.ioKit` if the I/O counters can't be read; usage falls back to
    ///   zero free/total only if the volume query fails (the volume query rarely fails for `/`).
    func sample(now: Date = Date()) throws -> DiskSample {
        let (free, total) = readUsage()
        let current = try Self.readIOCounters(now: now)
        defer { priorIO = current }

        let (read, write): (Double, Double)
        if let prior = priorIO {
            let interval = current.timestamp.timeIntervalSince(prior.timestamp)
            read = RateMath.bytesPerSecond(priorBytes: prior.readBytes, currentBytes: current.readBytes, interval: interval)
            write = RateMath.bytesPerSecond(priorBytes: prior.writeBytes, currentBytes: current.writeBytes, interval: interval)
        } else {
            (read, write) = (0, 0) // fresh sample: no prior → zero-rate, not a spike
        }

        return DiskSample(freeBytes: free, totalBytes: total, readBytesPerSec: read, writeBytesPerSec: write)
    }

    /// Boot-volume free/total via `URLResourceValues`. Returns zeroes if the query fails
    /// rather than throwing — usage is a best-effort field and the rest of the sample is still
    /// useful.
    private func readUsage() -> (free: UInt64, total: UInt64) {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let values = try? bootVolume.resourceValues(forKeys: keys) else {
            return (0, 0)
        }
        let free = UInt64(values.volumeAvailableCapacityForImportantUsage ?? 0)
        let total = UInt64(values.volumeTotalCapacity ?? 0)
        return (free, total)
    }

    /// Sum cumulative `Bytes (Read)` / `Bytes (Write)` across all `IOBlockStorageDriver`
    /// services. Each driver's `Statistics` dict carries the 64-bit byte counters.
    static func readIOCounters(now: Date = Date()) throws -> IOCounters {
        let matching = IOServiceMatching("IOBlockStorageDriver")
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard kr == KERN_SUCCESS else {
            throw CollectorError.ioKit(detail: "IOServiceGetMatchingServices(IOBlockStorageDriver) -> \(kr)")
        }
        defer { IOObjectRelease(iterator) }

        var totalRead: UInt64 = 0
        var totalWrite: UInt64 = 0
        var sawAny = false

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let stats = dict[statisticsKey] as? [String: Any] else {
                continue
            }
            sawAny = true
            if let r = (stats[bytesReadKey] as? NSNumber)?.uint64Value {
                totalRead &+= r
            }
            if let w = (stats[bytesWrittenKey] as? NSNumber)?.uint64Value {
                totalWrite &+= w
            }
        }

        guard sawAny else {
            throw CollectorError.ioKit(detail: "no IOBlockStorageDriver Statistics found")
        }
        return IOCounters(readBytes: totalRead, writeBytes: totalWrite, timestamp: now)
    }
}
