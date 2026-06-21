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

    // MARK: - Live detail sample (sub-cadence carry-forward — the OQ3 flicker fix)

    /// Per-process attribution is collected only every Nth tick (KTD3 sub-cadence), so `latest`
    /// carries it on ~1/N ticks. The live detail body must carry the most recent attribution
    /// forward across the base-tick gap — otherwise the process list flickers back to
    /// "Collecting data…" 2 of every 3 seconds.
    @MainActor
    func testLiveDetailSampleCarriesAttributionAcrossSubCadenceGap() {
        let ring = RingBuffer()
        let attr = AttributionSample(bySubsystem: [.cpu: [
            ProcessAttribution(pid: 1, name: "hot", subsystem: .cpu, value: 0.9, restricted: false)]])
        // A detail tick (has attribution) followed by two base-only ticks (the sub-cadence gap);
        // the newest tick has nil attribution, exactly as the governor emits it.
        ring.receive(Sample(timestamp: Date(timeIntervalSince1970: 100),
                            cpu: CPUSample(overall: 0.4, perCore: [0.4]), attribution: attr))
        ring.receive(Sample(timestamp: Date(timeIntervalSince1970: 101), cpu: CPUSample(overall: 0.5, perCore: [0.5])))
        ring.receive(Sample(timestamp: Date(timeIntervalSince1970: 102), cpu: CPUSample(overall: 0.6, perCore: [0.6])))
        let live = LiveModel(ring: ring)

        let resolved = PanelData.liveDetailSample(live)
        XCTAssertEqual(resolved?.attribution?.bySubsystem[.cpu]?.first?.name, "hot",
                       "attribution carries forward across the sub-cadence gap (no flicker to nil)")
        XCTAssertEqual(resolved?.cpu?.overall ?? -1, 0.6, accuracy: 0.0001,
                       "base metrics still come from the newest tick, not the carried-forward one")
    }

    /// Staleness bound: an attribution reading older than the sub-cadence lookback window (e.g. a
    /// previous panel session — the ring retains ~30 min) must NOT be shown as live; the body
    /// correctly falls back to "Collecting data…".
    @MainActor
    func testLiveDetailSampleDropsAttributionOlderThanWindow() {
        let ring = RingBuffer()
        let attr = AttributionSample(bySubsystem: [.cpu: [
            ProcessAttribution(pid: 1, name: "old", subsystem: .cpu, value: 0.9, restricted: false)]])
        ring.receive(Sample(timestamp: Date(timeIntervalSince1970: 100),
                            cpu: CPUSample(overall: 0.4, perCore: [0.4]), attribution: attr))
        // More base-only ticks than the lookback window → the old reading ages out.
        for i in 1...(Cadence.detailSubCadenceFactor * 2 + 2) {
            ring.receive(Sample(timestamp: Date(timeIntervalSince1970: 100 + Double(i)),
                                cpu: CPUSample(overall: 0.5, perCore: [0.5])))
        }
        let live = LiveModel(ring: ring)
        XCTAssertNil(PanelData.liveDetailSample(live)?.attribution,
                     "attribution older than the sub-cadence window is not shown as live")
    }
}
