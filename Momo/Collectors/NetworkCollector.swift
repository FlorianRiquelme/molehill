//
//  NetworkCollector.swift
//  System-wide network throughput collector (R1). Per-process network is out of scope (KTD6).
//
//  Source: `sysctl(NET_RT_IFLIST2)` walks the kernel interface list as `if_msghdr2` records,
//  whose `if_data64` carries 64-bit `ifi_ibytes` / `ifi_obytes` cumulative counters. We sum
//  rx/tx across all non-loopback interfaces and DIFF between samples (KTD11 delta-of-counters).
//
//  Why NET_RT_IFLIST2 over `getifaddrs`: `getifaddrs`' `struct if_data` exposes only 32-bit
//  byte counters, which wrap in seconds on a fast link; `if_data64` is 64-bit and won't wrap
//  in practice. `NET_RT_IFLIST2` (6) and `RTM_IFINFO2` (0x12) are stable BSD routing-socket
//  constants but live behind a PRIVATE guard in the public `route.h`, so they are pinned here.
//
//  Concurrency (KTD11): a class confined to the governor queue, owns the prior counter
//  snapshot for the rate delta, NOT `Sendable`. Produces a `Sendable` `NetworkSample`.
//
import Foundation

/// Cumulative rx/tx byte counters summed across non-loopback interfaces, with read instant.
struct NetCounters: Equatable {
    var rxBytes: UInt64
    var txBytes: UInt64
    var timestamp: Date
}

final class NetworkCollector: MetricCollector {
    // Pinned BSD constants (PRIVATE in the public route.h — see file header).
    private static let netRtIflist2: Int32 = 6
    private static let rtmIfinfo2: UInt8 = 0x12

    private var prior: NetCounters?

    init() {}

    func reset() { prior = nil }

    /// Read cumulative rx/tx counters, diff against the prior snapshot, produce a
    /// `NetworkSample`. First call after init/reset has no prior → zero-rate, never a spike.
    /// - Throws: `CollectorError.sysctl` / `.malformedReply` on a failed/short kernel reply.
    func sample(now: Date = Date()) throws -> NetworkSample {
        let current = try Self.readCounters(now: now)
        defer { prior = current }

        guard let prior else {
            return NetworkSample(rxBytesPerSec: 0, txBytesPerSec: 0) // fresh sample
        }
        let interval = current.timestamp.timeIntervalSince(prior.timestamp)
        return NetworkSample(
            rxBytesPerSec: RateMath.bytesPerSecond(priorBytes: prior.rxBytes, currentBytes: current.rxBytes, interval: interval),
            txBytesPerSec: RateMath.bytesPerSecond(priorBytes: prior.txBytes, currentBytes: current.txBytes, interval: interval)
        )
    }

    /// Walk `NET_RT_IFLIST2` and sum 64-bit rx/tx across non-loopback interfaces.
    static func readCounters(now: Date = Date()) throws -> NetCounters {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, netRtIflist2, 0]

        // First pass: ask for the buffer size.
        var needed = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &needed, nil, 0) == 0 else {
            throw CollectorError.sysctl(name: "NET_RT_IFLIST2(size)", errno: errno)
        }
        var buffer = [UInt8](repeating: 0, count: needed)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &needed, nil, 0) == 0 else {
            throw CollectorError.sysctl(name: "NET_RT_IFLIST2(data)", errno: errno)
        }

        var rxSum: UInt64 = 0
        var txSum: UInt64 = 0

        try buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr2>.size <= needed {
                // ifm_msglen is the first u_short of every routing message.
                let msgLen = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard msgLen > 0, offset + msgLen <= needed else {
                    throw CollectorError.malformedReply(detail: "NET_RT_IFLIST2 message length \(msgLen) at offset \(offset)")
                }
                let type = raw.load(fromByteOffset: offset + MemoryLayout<UInt16>.size + MemoryLayout<UInt8>.size, as: UInt8.self)
                if type == rtmIfinfo2 {
                    let hdr = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    // Skip loopback — system-wide throughput excludes lo0.
                    if (hdr.ifm_flags & Int32(IFF_LOOPBACK)) == 0 {
                        rxSum &+= hdr.ifm_data.ifi_ibytes
                        txSum &+= hdr.ifm_data.ifi_obytes
                    }
                }
                offset += msgLen
            }
        }
        return NetCounters(rxBytes: rxSum, txBytes: txSum, timestamp: now)
    }
}
