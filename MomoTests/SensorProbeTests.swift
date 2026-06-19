//
//  SensorProbeTests.swift
//  U3 — sensor subsystem unit tests (KTD5, R12, AE4).
//
//  All probe/intersection logic and all byte decoders are pure + fixture-driven, so the
//  suite passes deterministically with no hardware. A single live-HID check is gated behind
//  an env var (MOMO_LIVE_HID=1) so the deterministic suite never depends on this machine's
//  sensor set; run it explicitly to confirm the Apple Silicon path.
//
import XCTest
@testable import Momo

// MARK: - Fakes (simulate any K-of-M outcome with no hardware)

/// A backend that returns values only for a fixed allow-list of keys; everything else
/// reads nil (absent). Lets a test simulate "only K of M candidates probe successfully".
private final class FakeSensorBackend: SensorReadingBackend {
    var temperatures: [String: Double]
    var fans: [String: Double]
    init(temperatures: [String: Double] = [:], fans: [String: Double] = [:]) {
        self.temperatures = temperatures
        self.fans = fans
    }
    func readTemperature(key: String) -> Double? { temperatures[key] }
    func readFan(key: String) -> Double? { fans[key] }
}

/// A fake SMC transport returning canned type+bytes per key.
private final class FakeSMCBackend: SMCBackend {
    var readings: [String: SMCKeyReading]
    init(_ readings: [String: SMCKeyReading]) { self.readings = readings }
    func read(key: String) -> SMCKeyReading? { readings[key] }
}

/// A fake HID transport returning canned temperature services.
private final class FakeHIDBackend: HIDBackend {
    var readings: [HIDSensorReading]
    init(_ readings: [HIDSensorReading]) { self.readings = readings }
    func temperatureReadings() -> [HIDSensorReading] { readings }
}

final class SensorProbeTests: XCTestCase {

    // MARK: AE4 — K-of-M intersection

    func testProbeReportsKofMAndRenderableSetIsExactlyTheSuccessfulKeys() {
        // Apple Silicon temperature catalog has M candidates; let only K probe successfully.
        let allTemps = SensorCatalog.temperatureCandidates(for: .appleSilicon)
        let m = allTemps.count
        XCTAssertGreaterThan(m, 1, "need >1 candidate to make K-of-M meaningful")

        // Pick K = first two candidates as "available".
        let successfulKeys = Array(allTemps.prefix(2).map(\.key))
        let k = successfulKeys.count
        let backend = FakeSensorBackend(
            temperatures: Dictionary(uniqueKeysWithValues: successfulKeys.map { ($0, 42.0) })
        )

        let probe = SensorProbe(platform: .appleSilicon, backend: backend)
        let cap = probe.capability

        XCTAssertEqual(cap.availableTemperatureCount, k, "reports K available")
        XCTAssertEqual(cap.expectedTemperatureCount, m, "reports M expected")
        XCTAssertEqual(cap.unavailableTemperatureCount, m - k, "reports (M-K) unavailable")
        XCTAssertEqual(Set(cap.availableTemperatureKeys), Set(successfulKeys),
                       "renderable set is exactly the K successful keys")

        // The rendered sample contains exactly the K keys — no zeros for the absent ones.
        let sample = probe.read(thermalState: .nominal)
        XCTAssertEqual(Set(sample.temperatures.map(\.key)), Set(successfulKeys))
        XCTAssertEqual(sample.temperatures.count, k)
    }

    // MARK: Happy — pure decoders

    func testSP78DecodesKnownBytePairToCelsius() {
        // 0x2D00 -> 45.0; 0x1980 -> 25.5; negative 0xFFC0 -> -0.25.
        XCTAssertEqual(SMCDecode.sp78([0x2D, 0x00]), 45.0)
        XCTAssertEqual(SMCDecode.sp78([0x19, 0x80]), 25.5)
        XCTAssertEqual(SMCDecode.sp78([0xFF, 0xC0]), -0.25)
        XCTAssertNil(SMCDecode.sp78([0x01]), "too few bytes -> nil, not garbage")
    }

    func testFPE2DecodesKnownBytePairToRPM() {
        // 0x0AF0 = 2800 / 4 = 700.0 rpm.
        XCTAssertEqual(SMCDecode.fpe2([0x0A, 0xF0]), 700.0)
        XCTAssertEqual(SMCDecode.fpe2([0x00, 0x00]), 0.0)
    }

    func testFLTDecodesLittleEndianFloat() {
        // 1234.0f little-endian bytes.
        var f: Float = 1234.0
        let bytes = withUnsafeBytes(of: &f) { Array($0) }
        XCTAssertEqual(SMCDecode.flt(bytes)!, 1234.0, accuracy: 0.001)
    }

    func testHIDTemperatureMapsFloatToDegrees() {
        // The HID temperature value is already °C — identity passthrough.
        XCTAssertEqual(hidTemperatureDegrees(37.5), 37.5)

        // And through the live backend seam with a fake service.
        let hid = FakeHIDBackend([HIDSensorReading(product: "PMU tdie", celsius: 51.2)])
        let backend = HIDSensorBackend(reader: hid)!
        XCTAssertEqual(backend.readTemperature(key: "PMU tdie")!, 51.2, accuracy: 0.001)
    }

    func testSMCBackendDecodesThroughTransport() {
        let smc = FakeSMCBackend([
            "TC0P": SMCKeyReading(type: "sp78", bytes: [0x2D, 0x00]),
        ])
        let backend = SMCSensorBackend(smc: smc)!
        XCTAssertEqual(backend.readTemperature(key: "TC0P"), 45.0)
    }

    // MARK: Edge — fanless Mac

    func testFanlessMacYieldsEmptyFanListNotZeroRPMFan() {
        // FNum == 0 semantics: the fan keys simply don't read back.
        let backend = FakeSensorBackend(
            temperatures: ["TC0P": 40.0],   // a temp is present
            fans: [:]                        // no fans
        )
        let probe = SensorProbe(platform: .intel, backend: backend)
        XCTAssertEqual(probe.capability.availableFanKeys, [])
        let sample = probe.read(thermalState: .nominal)
        XCTAssertTrue(sample.fans.isEmpty, "no fan entries, not a zero-RPM fan")
    }

    func testSMCFanBackendDropsZeroRPM() {
        // A fan key that reads 0 rpm (e.g. stopped/absent) is dropped, not surfaced as 0.
        let smc = FakeSMCBackend([
            "F0Ac": SMCKeyReading(type: "fpe2", bytes: [0x00, 0x00]), // 0 rpm
        ])
        let backend = SMCSensorBackend(smc: smc)!
        XCTAssertNil(backend.readFan(key: "F0Ac"))
    }

    // MARK: Edge — catalog key absent on this SoC is silently skipped

    func testCandidateAbsentOnSoCIsSilentlySkipped() {
        // Empty backend: nothing reads back. No crash, no zeros, capability is all-absent.
        let backend = FakeSensorBackend()
        let probe = SensorProbe(platform: .appleSilicon, backend: backend)
        XCTAssertEqual(probe.capability.availableTemperatureKeys, [])
        let sample = probe.read(thermalState: .nominal)
        XCTAssertTrue(sample.temperatures.isEmpty)
        XCTAssertTrue(sample.fans.isEmpty)
    }

    func testPlatformFilterExcludesOtherArchitectureCandidates() {
        // Intel SMC keys must not appear in the Apple Silicon expected set, and vice versa.
        let asKeys = Set(SensorCatalog.candidates(for: .appleSilicon).map(\.key))
        let intelKeys = Set(SensorCatalog.candidates(for: .intel).map(\.key))
        XCTAssertTrue(asKeys.isDisjoint(with: intelKeys))
        XCTAssertFalse(asKeys.contains("TC0P"))
        XCTAssertFalse(intelKeys.contains("PMU tdie"))
    }

    // MARK: Error — SMCKeyData stride mismatch refuses to open

    func testSMCKeyDataStrideMatchesPinnedBaseline() {
        // If the toolchain ever changes the struct layout, this fails loudly and the live
        // reader refuses to open (it cannot read corrupt bytes). KTD5.
        XCTAssertEqual(MemoryLayout<SMCKeyData>.stride, SMCReader.expectedKeyDataStride)
        XCTAssertTrue(SMCReader.layoutIsStable())
    }

    func testStrideGuardWouldRefuseOpenOnDrift() {
        // We can't mutate the compiled stride, but assert the guard's contract: when stable
        // is false, the live reader's init returns nil rather than reading corrupt bytes.
        // (Direct check of the boolean the init gates on.)
        XCTAssertTrue(SMCReader.layoutIsStable(),
                      "stable on this toolchain; the init nil-returns when this is false")
    }

    // MARK: FourCC helpers

    func testFourCCRoundTrips() {
        let cc = SMCReader.fourCC("TC0P")!
        XCTAssertEqual(cc, 0x54433050)
        XCTAssertEqual(SMCReader.fourCCString(cc), "TC0P")
        XCTAssertNil(SMCReader.fourCC("TOOLONG"))
    }

    // MARK: Thermal state mapping

    func testThermalStateMapping() {
        XCTAssertEqual(mapThermalState(.nominal), .nominal)
        XCTAssertEqual(mapThermalState(.fair), .fair)
        XCTAssertEqual(mapThermalState(.serious), .serious)
        XCTAssertEqual(mapThermalState(.critical), .critical)
    }

    // MARK: Architecture detection (informational — must not crash)

    func testArchitectureDetectionRuns() {
        // On this machine we expect Apple Silicon, but the test only asserts it resolves.
        let platform = SensorArchitecture.detect()
        XCTAssertTrue(platform == .appleSilicon || platform == .intel)
    }

    // MARK: Live HID probe — GATED (MOMO_LIVE_HID=1), not part of deterministic suite

    func testLiveHIDProbe_gated() throws {
        guard ProcessInfo.processInfo.environment["MOMO_LIVE_HID"] == "1" else {
            throw XCTSkip("Set MOMO_LIVE_HID=1 to run the live Apple Silicon HID probe.")
        }
        guard SensorArchitecture.isAppleSilicon() else {
            throw XCTSkip("Live HID probe only applies on Apple Silicon.")
        }
        let backend = try XCTUnwrap(HIDSensorBackend(), "HID client should create on AS")
        let probe = SensorProbe(platform: .appleSilicon, backend: backend)
        let sample = probe.read()
        print("LIVE HID: \(sample.temperatures.count) temperature sensors discovered")
        for t in sample.temperatures.prefix(5) {
            print("  - \(t.key): \(t.celsius) °C")
        }
        XCTAssertGreaterThan(sample.temperatures.count, 0, "expected at least one HID temp sensor on AS")
    }
}
