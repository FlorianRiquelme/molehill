//
//  SensorCatalog.swift
//  Per-SoC declarative candidate-key catalog (KTD5, R12).
//
//  SMC/HID sensor keys change every SoC generation, and macOS 26 removed
//  `powermetrics --samplers smc`, so the set of sensors a Mac exposes is data, not
//  code. This catalog declares the *candidate* keys/services to try per platform; the
//  runtime probe (SensorProbe) keeps only those that actually read back. Absent
//  candidates are omitted — never rendered as zero (R12, AE4).
//
//  Modelled on exelban/stats `Modules/Sensors/values.swift`: a flat candidate list with
//  a `platforms` filter rather than a per-machine hardcoded table.
//
import Foundation

/// Which sensor backend a candidate is read through. Determined by the SoC architecture
/// at launch (SensorProbe): Intel goes through `AppleSMC`, Apple Silicon through
/// `IOHIDEventSystemClient`.
enum SensorPlatform: Sendable, Equatable {
    case intel        // AppleSMC IOKit user-client
    case appleSilicon // IOHIDEventSystemClient (private HID)
}

/// What a candidate measures.
enum SensorKind: Sendable, Equatable {
    case temperature
    case fan
}

/// One sensor we *might* be able to read on some Mac. The probe decides whether this
/// machine actually exposes it. `key` is the lookup token: an SMC FourCC ("TC0P") on
/// Intel, or the HID service `Product` name on Apple Silicon.
struct SensorCandidate: Sendable, Equatable {
    let key: String
    let label: String
    let kind: SensorKind
    /// Platforms on which this candidate is even worth trying. The probe never attempts
    /// an Intel SMC key on Apple Silicon (or vice versa), so a candidate absent on the
    /// current platform is simply not in the expected set (not counted as "unavailable").
    let platforms: [SensorPlatform]
}

/// The declarative candidate catalog. Static data; no machine-specific branching here —
/// the probe does the per-machine resolution.
enum SensorCatalog {
    /// Every candidate we know how to try. Kept deliberately small and representative;
    /// SMC keys are the stable cross-generation Intel set, HID candidates are matched by
    /// service `Product` name on Apple Silicon (where keys are not FourCCs).
    static let all: [SensorCandidate] = intelCandidates + appleSiliconCandidates

    /// Intel `AppleSMC` candidates (fixture-tested only — no Intel hardware, U3/OQ9).
    static let intelCandidates: [SensorCandidate] = [
        SensorCandidate(key: "TC0P", label: "CPU Proximity", kind: .temperature, platforms: [.intel]),
        SensorCandidate(key: "TC0D", label: "CPU Die", kind: .temperature, platforms: [.intel]),
        SensorCandidate(key: "TG0P", label: "GPU Proximity", kind: .temperature, platforms: [.intel]),
        SensorCandidate(key: "TM0P", label: "Memory Proximity", kind: .temperature, platforms: [.intel]),
        SensorCandidate(key: "Ts0P", label: "Palm Rest", kind: .temperature, platforms: [.intel]),
        // Fans: enumerated via FNum/F*Ac at probe time, but a candidate per fan index lets
        // the intersection logic report expected-but-absent fans uniformly.
        SensorCandidate(key: "F0Ac", label: "Fan 0", kind: .fan, platforms: [.intel]),
        SensorCandidate(key: "F1Ac", label: "Fan 1", kind: .fan, platforms: [.intel]),
    ]

    /// Apple Silicon `IOHIDEventSystemClient` candidates. Matched by service friendly
    /// name (`Product`); the substrings here are the stable family identifiers across
    /// M-series parts (live-verifiable on this machine).
    static let appleSiliconCandidates: [SensorCandidate] = [
        SensorCandidate(key: "PMU tdie", label: "CPU Die", kind: .temperature, platforms: [.appleSilicon]),
        SensorCandidate(key: "PMU tdev", label: "CPU Package", kind: .temperature, platforms: [.appleSilicon]),
        SensorCandidate(key: "gas gauge", label: "Battery", kind: .temperature, platforms: [.appleSilicon]),
        SensorCandidate(key: "NAND", label: "SSD", kind: .temperature, platforms: [.appleSilicon]),
    ]

    /// Candidates worth trying on `platform` — the left operand of the
    /// `(platform-filtered catalog) ∩ (probed successfully)` intersection (KTD5).
    static func candidates(for platform: SensorPlatform) -> [SensorCandidate] {
        all.filter { $0.platforms.contains(platform) }
    }

    static func temperatureCandidates(for platform: SensorPlatform) -> [SensorCandidate] {
        candidates(for: platform).filter { $0.kind == .temperature }
    }

    static func fanCandidates(for platform: SensorPlatform) -> [SensorCandidate] {
        candidates(for: platform).filter { $0.kind == .fan }
    }
}
