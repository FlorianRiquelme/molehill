//
//  Sample.swift
//  Layer-neutral domain model (KTD11 / KTD12).
//
//  Every type here is an immutable, `Sendable` value type. A `Sample` is assembled
//  once per governor tick on the collection queue and handed — by value — across the
//  single main-actor hop and to the recording store. Collectors and the store both
//  depend *down* onto these types; GRDB row types (Store/) own the Sample -> table
//  translation so the irreversible schema never leaks into the live path.
//
//  Subsystem fields are optional so a Sample can be assembled from whatever collectors
//  produced this tick (a missing sensor must never be rendered as zero — KTD5/R12), and
//  so sub-cadence subsystems (sensors, per-process) are simply absent on ticks they
//  don't run.
//
import Foundation

/// Immutable per-tick snapshot of the machine. Assembled by the ingest assembler,
/// fanned out unchanged to the ring buffer and the store (KTD12).
struct Sample: Sendable, Equatable {
    /// Absolute instant of the tick. The store converts this to UTC epoch seconds
    /// for bucketing/retention (KTD2); timezone is a display-only concern.
    let timestamp: Date

    let cpu: CPUSample?
    let memory: MemorySample?
    let disk: DiskSample?
    let network: NetworkSample?
    let sensors: SensorSample?
    let attribution: AttributionSample?
    let context: CorrelatedState

    init(
        timestamp: Date,
        cpu: CPUSample? = nil,
        memory: MemorySample? = nil,
        disk: DiskSample? = nil,
        network: NetworkSample? = nil,
        sensors: SensorSample? = nil,
        attribution: AttributionSample? = nil,
        context: CorrelatedState = CorrelatedState()
    ) {
        self.timestamp = timestamp
        self.cpu = cpu
        self.memory = memory
        self.disk = disk
        self.network = network
        self.sensors = sensors
        self.attribution = attribution
        self.context = context
    }
}

// MARK: - System metrics (populated by U2)

/// CPU utilization (R1). Values are fractions in 0...1.
struct CPUSample: Sendable, Equatable {
    let overall: Double
    let perCore: [Double]
}

/// Memory state (R1).
struct MemorySample: Sendable, Equatable {
    enum Pressure: Int, Sendable, Equatable { case normal = 1, warning = 2, critical = 4 }
    let usedBytes: UInt64
    let totalBytes: UInt64
    let pressure: Pressure
    let swapUsedBytes: UInt64
}

/// Disk usage + I/O throughput (R1). Rates are bytes/second over the sample interval.
struct DiskSample: Sendable, Equatable {
    let freeBytes: UInt64
    let totalBytes: UInt64
    let readBytesPerSec: Double
    let writeBytesPerSec: Double
}

/// System-wide network throughput (R1). Per-process network is out of scope (KTD6).
struct NetworkSample: Sendable, Equatable {
    let rxBytesPerSec: Double
    let txBytesPerSec: Double
}

// MARK: - Sensors (populated by U3)

/// Temperatures + fans resolved through the capability probe (R1 temps/fans, R12).
/// Only sensors that probed successfully appear; absence is never zero.
struct SensorSample: Sendable, Equatable {
    let temperatures: [SensorReading]
    let fans: [FanReading]
    /// Coarse public throttling marker (`ProcessInfo.thermalState`).
    let thermalState: ThermalState

    enum ThermalState: Int, Sendable, Equatable { case nominal, fair, serious, critical }
}

struct SensorReading: Sendable, Equatable, Identifiable {
    let key: String          // catalog key (e.g. SMC "TC0P" or HID service name)
    let label: String        // friendly name
    let celsius: Double
    var id: String { key }
}

struct FanReading: Sendable, Equatable, Identifiable {
    let key: String
    let label: String
    let rpm: Double
    var id: String { key }
}

// MARK: - Per-process attribution (populated by U4)

/// Subsystems that support per-process attribution (KTD6: network excluded).
enum Subsystem: String, Sendable, Equatable, CaseIterable {
    case cpu, memory, disk
}

/// Top-N responsible processes per subsystem, captured at record time (R6). Cannot be
/// backfilled — the per-tick `value` is what U6 aggregates into `value`/`value_max`
/// at rollup (KTD4a), so it must be carried here.
struct AttributionSample: Sendable, Equatable {
    /// Top-N rows per subsystem.
    let bySubsystem: [Subsystem: [ProcessAttribution]]
}

/// One process's contribution to one subsystem for one tick.
struct ProcessAttribution: Sendable, Equatable, Identifiable {
    let pid: Int32
    /// Leaf executable name ONLY (KTD4b) — never the full `proc_pidpath`.
    let name: String
    let subsystem: Subsystem
    /// Per-tick value: CPU fraction, resident bytes, or disk bytes/sec by subsystem.
    let value: Double
    /// True when the process could not be read (EPERM/root) — surfaced, not dropped.
    let restricted: Bool

    var id: String { "\(subsystem.rawValue):\(pid)" }
}

// MARK: - Correlated state (populated by U4/U5)

/// Foreground app + power state at sample time (R6). Both age out at the 1h tier (KTD4).
struct CorrelatedState: Sendable, Equatable {
    let foregroundApp: String?
    let power: PowerSnapshot

    init(foregroundApp: String? = nil, power: PowerSnapshot = PowerSnapshot()) {
        self.foregroundApp = foregroundApp
        self.power = power
    }
}

/// Immutable power snapshot read by the governor (cadence) and U4 (correlated state) —
/// the single `Sendable` value both consume (KTD11). Produced by U5's `PowerContext`.
struct PowerSnapshot: Sendable, Equatable {
    let onBattery: Bool
    let lowPowerMode: Bool
    let displayAttached: Bool
    let asleep: Bool

    init(onBattery: Bool = false, lowPowerMode: Bool = false, displayAttached: Bool = true, asleep: Bool = false) {
        self.onBattery = onBattery
        self.lowPowerMode = lowPowerMode
        self.displayAttached = displayAttached
        self.asleep = asleep
    }
}
