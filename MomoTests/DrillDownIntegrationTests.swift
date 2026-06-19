//
//  DrillDownIntegrationTests.swift
//  U8 — drill-down behavior at the pipeline level: opening a panel (DetailVisible) turns on
//  per-process + sensor collection (KTD3), and sensor reads refresh live (the U8 fix). The
//  panel rendering itself is integration-verified by launching the app.
//
import XCTest
import os
@testable import Momo

// MARK: - Fakes

private final class FakeTimer: GovernorTimer, @unchecked Sendable {
    private var handler: (() -> Void)?
    func schedule(interval: TimeInterval, leeway: TimeInterval, handler: @escaping () -> Void) { self.handler = handler }
    func cancel() { handler = nil }
    func fire() { handler?() }
}

private final class FakePowerContext: PowerContextProtocol, @unchecked Sendable {
    var snap = PowerSnapshot()   // AC, display attached, awake -> not throttled
    var onChange: (@Sendable () -> Void)?
    func snapshot() -> PowerSnapshot { snap }
    func updateSleepState(asleep: Bool) {
        snap = PowerSnapshot(onBattery: snap.onBattery, lowPowerMode: snap.lowPowerMode,
                             displayAttached: snap.displayAttached, asleep: asleep)
    }
    func updateDisplayAttached(_ attached: Bool) {}
}

/// Caches its reading like the real HID backend; only `refresh()` re-snapshots the live value.
private final class FakeSensorBackend: SensorReadingBackend, @unchecked Sendable {
    var liveTemp: Double
    private var cached: Double
    private(set) var refreshCount = 0
    init(temp: Double) { liveTemp = temp; cached = temp }
    func readTemperature(key: String) -> Double? { cached }   // every catalog key "available"
    func readFan(key: String) -> Double? { nil }
    func refresh() { refreshCount += 1; cached = liveTemp }
}

private final class CaptureReceiver: SampleReceiver, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [Sample]())
    func receive(_ sample: Sample) { lock.withLock { $0.append(sample) } }
    var samples: [Sample] { lock.withLock { $0 } }
}

// MARK: - Tests

final class DrillDownIntegrationTests: XCTestCase {

    /// The U8 fix: SensorProbe.read() refreshes the (caching) backend so live values aren't stale.
    func testSensorReadRefreshesBackend() {
        let backend = FakeSensorBackend(temp: 40)
        let probe = SensorProbe(platform: .appleSilicon, backend: backend)

        backend.liveTemp = 55                 // machine got hotter; cache still 40
        let sample = probe.read(thermalState: .nominal)

        XCTAssertGreaterThanOrEqual(backend.refreshCount, 1, "read() must refresh the backend")
        XCTAssertEqual(sample.temperatures.first?.celsius, 55, "read reflects the refreshed live value, not the stale cache")
    }

    private func makeGovernor(probe: SensorProbe?, sink: SampleSink, timer: FakeTimer) throws -> PollingGovernor {
        try PollingGovernor(
            sink: sink, power: FakePowerContext(),
            cpu: CPUCollector(), memory: MemoryCollector(), disk: DiskCollector(), network: NetworkCollector(),
            attribution: ProcessAttributionCollector(foregroundProvider: { "Test" }),
            sensorProbe: probe, timer: timer)
    }

    func testDetailVisibleCollectsPerProcessAndSensors() throws {
        let sink = SampleSink()
        let capture = CaptureReceiver()
        sink.register(capture)
        let timer = FakeTimer()
        let probe = SensorProbe(platform: .appleSilicon, backend: FakeSensorBackend(temp: 42))
        let gov = try makeGovernor(probe: probe, sink: sink, timer: timer)

        gov.start()
        gov.setDetailVisible(true, metrics: [.cpu, .sensors])
        _ = gov.plan                          // barrier: drain async start()/setDetailVisible

        // Sub-cadence factor is 3 → the 3rd wakeup is the detail tick.
        timer.fire(); timer.fire(); timer.fire()

        let samples = capture.samples
        XCTAssertFalse(samples.isEmpty)
        // Memory attribution is instantaneous, so it appears on the first detail tick.
        XCTAssertTrue(samples.contains { ($0.attribution?.bySubsystem[.memory]?.isEmpty == false) },
                      "per-process attribution collected while DetailVisible")
        XCTAssertTrue(samples.contains { ($0.sensors?.temperatures.isEmpty == false) },
                      "sensors collected (and refreshed) while DetailVisible")
    }

    func testMenuBarOnlyPausesDetailCollection() throws {
        let sink = SampleSink()
        let capture = CaptureReceiver()
        sink.register(capture)
        let timer = FakeTimer()
        let probe = SensorProbe(platform: .appleSilicon, backend: FakeSensorBackend(temp: 42))
        let gov = try makeGovernor(probe: probe, sink: sink, timer: timer)

        gov.start()                            // no panel -> MenuBarOnly
        _ = gov.plan
        timer.fire(); timer.fire(); timer.fire()

        let samples = capture.samples
        XCTAssertFalse(samples.isEmpty)
        // KTD3: detail tier paused when nothing is visible — no attribution, no sensors.
        XCTAssertTrue(samples.allSatisfy { $0.attribution == nil }, "per-process paused in MenuBarOnly")
        XCTAssertTrue(samples.allSatisfy { $0.sensors == nil }, "sensors paused in MenuBarOnly")
        // But cheap menu-bar metrics still flow.
        XCTAssertTrue(samples.contains { $0.cpu != nil })
    }
}
