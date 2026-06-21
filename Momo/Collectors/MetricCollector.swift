//
//  MetricCollector.swift
//  Uniform lifecycle for the system-metric collectors (KTD11 / KTD12).
//
//  The governor (U5) drives a heterogeneous set of collectors — CPU, memory, disk,
//  network — each producing its own `Sendable` partial sub-struct that the assembler
//  composes into one immutable `Sample` (KTD12). This protocol is *only* the common
//  lifecycle the governor needs to treat them uniformly; it deliberately does NOT abstract
//  over the partial type (no associated types), because the assembler wants each concrete
//  partial by name. Concrete collectors keep their own typed `sample(...)` method.
//
//  Concurrency contract (KTD11): collectors are reference types confined to the governor's
//  single serial queue. They own mutable prior-sample state for delta math, which is
//  race-free precisely because the governor is their sole owner — so they are explicitly
//  NOT `Sendable` (no actor, no locks; single-queue confinement is the contract).
//
import Foundation

/// Common lifecycle for governor-driven collectors. The per-collector `sample(...)` method
/// (each returning its own `Sendable` partial) is intentionally not part of this protocol —
/// only the lifecycle the governor invokes uniformly is.
///
/// Not `Sendable` by design: collectors carry mutable delta-math state and are confined to
/// the governor's serial queue (KTD11).
protocol MetricCollector: AnyObject {
    /// Discard any cached prior-sample snapshot so the next `sample(...)` is treated as a
    /// fresh first sample (no prior → nil/zero rate, never a spike). The governor calls this
    /// on resume from sleep and whenever a cadence gap would make a delta meaningless — a
    /// rate computed across a multi-minute sleep gap is garbage, so the snapshot is dropped
    /// rather than diffed.
    func reset()
}

/// Non-success `kern_return_t` from a `host_*` / IOKit call, or a malformed kernel reply.
/// Surfaced as a thrown error so the assembler omits the subsystem this tick (KTD5/R12:
/// a missing reading is absence, never a fabricated zero).
enum CollectorError: Error, Equatable {
    /// A `host_*` / mach call returned a non-`KERN_SUCCESS` status.
    case hostCall(api: String, code: Int32)
    /// An IOKit lookup or property read failed or returned an unexpected shape.
    case ioKit(detail: String)
    /// A `sysctl` / `sysctlbyname` call failed (`errno` captured).
    case sysctl(name: String, errno: Int32)
    /// A libproc call (`proc_listpids` / `proc_pidinfo` / `proc_pid_rusage`) failed.
    case libproc(api: String, errno: Int32)
    /// The kernel returned a reply whose shape/size did not match what we read — or a pinned
    /// struct stride drifted from its known-good baseline (KTD5 layout guard).
    case malformedReply(detail: String)
}
