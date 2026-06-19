//
//  SensorProbe.swift
//  Launch capability probe + the sensor subsystem's reading interface (KTD5, KTD11, R12).
//
//  At launch the probe detects the architecture, takes the platform-filtered catalog
//  (SensorCatalog), reads each candidate through the platform's backend, and resolves the
//  available set as the intersection:  (platform-filtered catalog) ∩ (probed successfully).
//  Absent candidates are reported as *unavailable* (count for the "N of M available" UI,
//  OQ6) — never rendered as zero (R12, AE4).
//
//  Concurrency (KTD11): the readers are classes confined to the governor queue and are NOT
//  `Sendable`; they produce the `Sendable` `SensorSample`. This unit deliberately does NOT
//  couple to U2's `MetricCollector` protocol (built in parallel) — it defines the sensor
//  subsystem's own small `read()` surface; U5's governor adapts it later.
//
import Foundation

// MARK: - Reading backend (injectable — the live IOKit/HID calls hide behind this)

/// The probe-and-read surface for one platform. The live implementations wrap SMC/HID
/// IOKit calls; tests inject a fake to simulate any K-of-M outcome without hardware.
protocol SensorReadingBackend {
    /// Read the current value for a temperature candidate `key`, or nil if absent / errors.
    func readTemperature(key: String) -> Double?
    /// Read the current RPM for a fan candidate `key`. nil = fan absent (fanless / fewer
    /// fans than candidates) — yields no fan entry, never a zero-RPM fan.
    func readFan(key: String) -> Double?
}

// MARK: - Probe result

/// The resolved capability of this machine's sensors. `expected` is the count of
/// platform-filtered candidates; `available` are the ones that read back. `unavailable`
/// drives the "N of M available" degraded-state UI (OQ6, AE4).
struct SensorCapability: Sendable, Equatable {
    let platform: SensorPlatform
    /// Candidate keys (temperatures) that probed successfully — the renderable set.
    let availableTemperatureKeys: [String]
    /// Candidate keys (fans) that probed successfully.
    let availableFanKeys: [String]
    /// Total temperature candidates expected on this platform (M, the catalog side).
    let expectedTemperatureCount: Int
    /// Total fan candidates expected on this platform.
    let expectedFanCount: Int

    /// K of M temperatures available.
    var availableTemperatureCount: Int { availableTemperatureKeys.count }
    /// (M − K) temperatures expected on this platform but not readable.
    var unavailableTemperatureCount: Int { expectedTemperatureCount - availableTemperatureKeys.count }
    var unavailableFanCount: Int { expectedFanCount - availableFanKeys.count }
}

// MARK: - Probe

/// Resolves which catalog candidates are actually readable on this machine and reads them.
/// Owns its backend + a cached capability; confined to the governor queue, not `Sendable`.
final class SensorProbe {
    private let platform: SensorPlatform
    private let backend: SensorReadingBackend
    /// Resolved once at launch and reused — the available set does not change per tick.
    private(set) var capability: SensorCapability

    /// Test/governor entry point: inject a backend + platform. The intersection runs once
    /// here so `capability` is ready before any tick is read (U5 drops pre-probe ticks).
    init(platform: SensorPlatform, backend: SensorReadingBackend) {
        self.platform = platform
        self.backend = backend
        self.capability = SensorProbe.resolve(platform: platform, backend: backend)
    }

    /// Pure intersection: (platform-filtered catalog) ∩ (keys that read back). Static and
    /// side-effect-free except for the backend reads, so it is the unit under test for AE4.
    static func resolve(platform: SensorPlatform, backend: SensorReadingBackend) -> SensorCapability {
        let tempCandidates = SensorCatalog.temperatureCandidates(for: platform)
        let fanCandidates = SensorCatalog.fanCandidates(for: platform)

        let availableTemps = tempCandidates
            .filter { backend.readTemperature(key: $0.key) != nil }
            .map(\.key)
        let availableFans = fanCandidates
            .filter { backend.readFan(key: $0.key) != nil }
            .map(\.key)

        return SensorCapability(
            platform: platform,
            availableTemperatureKeys: availableTemps,
            availableFanKeys: availableFans,
            expectedTemperatureCount: tempCandidates.count,
            expectedFanCount: fanCandidates.count
        )
    }

    /// Read the current sensor sample for the available set only. Absent candidates are
    /// never represented (no zero), satisfying R12 at the value level too. The label comes
    /// from the catalog; the thermal state is the coarse public marker (see below).
    func read(thermalState: SensorSample.ThermalState = currentThermalState()) -> SensorSample {
        let labels = labelIndex(for: platform)

        var temperatures: [SensorReading] = []
        for key in capability.availableTemperatureKeys {
            guard let celsius = backend.readTemperature(key: key) else { continue }
            temperatures.append(SensorReading(key: key, label: labels[key] ?? key, celsius: celsius))
        }

        var fans: [FanReading] = []
        for key in capability.availableFanKeys {
            guard let rpm = backend.readFan(key: key) else { continue }
            fans.append(FanReading(key: key, label: labels[key] ?? key, rpm: rpm))
        }

        return SensorSample(temperatures: temperatures, fans: fans, thermalState: thermalState)
    }

    private func labelIndex(for platform: SensorPlatform) -> [String: String] {
        Dictionary(SensorCatalog.candidates(for: platform).map { ($0.key, $0.label) },
                   uniquingKeysWith: { first, _ in first })
    }
}

// MARK: - Architecture detection

/// Detects whether to use the Apple Silicon (HID) or Intel (SMC) path. Used at launch to
/// pick the backend before any read (KTD5).
enum SensorArchitecture {
    static func detect() -> SensorPlatform {
        isAppleSilicon() ? .appleSilicon : .intel
    }

    /// `hw.optional.arm64` is 1 on Apple Silicon, absent/0 on Intel.
    static func isAppleSilicon() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return result == 0 && value == 1
    }
}

// MARK: - Coarse public throttling signals

/// Maps the public `ProcessInfo.processInfo.thermalState` to the domain `ThermalState`.
/// This is the privilege-free throttling marker (no SMC/HID required). NOTE: read the
/// `ProcessInfo.processInfo` *singleton* — a fresh `ProcessInfo()` corrupts the result.
func currentThermalState() -> SensorSample.ThermalState {
    mapThermalState(ProcessInfo.processInfo.thermalState)
}

/// Pure mapping (testable without touching the live singleton).
func mapThermalState(_ state: ProcessInfo.ThermalState) -> SensorSample.ThermalState {
    switch state {
    case .nominal: return .nominal
    case .fair: return .fair
    case .serious: return .serious
    case .critical: return .critical
    @unknown default: return .nominal
    }
}

/// Darwin notification name for the finer-grained thermal-pressure signal. Captured here
/// for later wiring (U5 governor); not observed in U3.
let thermalPressureNotificationName = "com.apple.system.thermalpressurelevel"

// MARK: - Live backends (wrap the SMC/HID readers behind the injectable surface)

/// Apple Silicon backend: resolves HID temperature services by matching the candidate
/// `key` as a substring of the service `Product` name. Fans are not exposed on the HID
/// temperature path, so `readFan` is always nil here (Apple Silicon fan RPM, where present,
/// is a separate effort — out of scope for this temperature-focused probe).
final class HIDSensorBackend: SensorReadingBackend {
    private let reader: HIDBackend
    /// Cached per-probe snapshot so the M reads in `resolve` see a consistent service set.
    private var readingsByProductLowercased: [(product: String, celsius: Double)]

    init?(reader: HIDBackend? = nil) {
        guard let reader = reader ?? HIDSensorReader() else { return nil }
        self.reader = reader
        self.readingsByProductLowercased = reader.temperatureReadings()
            .map { ($0.product.lowercased(), $0.celsius) }
    }

    /// Refresh the live service snapshot (governor calls this once per sensor sub-tick).
    func refresh() {
        readingsByProductLowercased = reader.temperatureReadings()
            .map { ($0.product.lowercased(), $0.celsius) }
    }

    func readTemperature(key: String) -> Double? {
        let needle = key.lowercased()
        return readingsByProductLowercased.first { $0.product.contains(needle) }?.celsius
    }

    func readFan(key: String) -> Double? { nil }
}

/// Intel backend: SMC user-client, fixture-tested only (OQ9). Decodes via `SMCDecode`.
final class SMCSensorBackend: SensorReadingBackend {
    private let smc: SMCBackend

    init?(smc: SMCBackend? = nil) {
        guard let smc = smc ?? SMCReader() else { return nil }
        self.smc = smc
    }

    func readTemperature(key: String) -> Double? {
        guard let r = smc.read(key: key) else { return nil }
        return SMCDecode.value(type: r.type, bytes: r.bytes)
    }

    func readFan(key: String) -> Double? {
        // Fanless Mac / absent fan index: FNum-gated. A candidate fan key that doesn't read
        // back yields nil here, so the probe omits it (no zero-RPM fan).
        guard let r = smc.read(key: key) else { return nil }
        guard let rpm = SMCDecode.value(type: r.type, bytes: r.bytes), rpm > 0 else { return nil }
        return rpm
    }
}
