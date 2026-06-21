//
//  PollingGovernorTests.swift
//  U5 — polling governor + power context (KTD3, R10, R11, AE3).
//
//  Two layers, both deterministic with no wall-clock:
//   1. The PURE cadence state machine (`CadencePlan.resolve`) — the single source of truth for
//      precedence (Suspended > DetailVisible > Throttled > MenuBarOnly), tested directly.
//   2. The live `PollingGovernor` driven through an injected fake timer + fake power context +
//      real collectors. The fake timer COUNTS create/cancel (guards the energy-leak
//      "forgot to invalidate" bug — KTD3) and lets a test fire ticks synchronously.
//
import XCTest
@testable import Momo

// MARK: - Fakes

/// Counts schedule/cancel and lets a test fire the handler deterministically (no wall clock).
private final class FakeTimer: GovernorTimer, @unchecked Sendable {
    private(set) var scheduleCount = 0
    private(set) var cancelCount = 0
    private(set) var lastInterval: TimeInterval?
    private(set) var lastLeeway: TimeInterval?
    private var handler: (() -> Void)?

    /// True while a wakeup is currently scheduled (scheduled and not since cancelled).
    private(set) var isRunning = false

    func schedule(interval: TimeInterval, leeway: TimeInterval, handler: @escaping () -> Void) {
        scheduleCount += 1
        lastInterval = interval
        lastLeeway = leeway
        self.handler = handler
        isRunning = true
    }

    func cancel() {
        // Match DispatchSourceTimer semantics: cancelling when nothing is scheduled is a no-op
        // for "running", but we still count the call so leak tests see every cancel attempt.
        cancelCount += 1
        handler = nil
        isRunning = false
    }

    /// Fire the scheduled handler once (simulating one coalesced wakeup).
    func fire() { handler?() }
}

/// A power context returning a fixed snapshot; mutable so tests flip battery/LPM/display/sleep.
private final class FakePowerContext: PowerContextProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var snap: PowerSnapshot
    var onChange: (@Sendable () -> Void)?

    init(_ snap: PowerSnapshot = PowerSnapshot()) { self.snap = snap }

    func snapshot() -> PowerSnapshot { lock.withLock { snap } }

    func updateSleepState(asleep: Bool) {
        lock.withLock { snap = PowerSnapshot(onBattery: snap.onBattery, lowPowerMode: snap.lowPowerMode,
                                             displayAttached: snap.displayAttached, asleep: asleep) }
    }
    func updateDisplayAttached(_ attached: Bool) {
        lock.withLock { snap = PowerSnapshot(onBattery: snap.onBattery, lowPowerMode: snap.lowPowerMode,
                                             displayAttached: attached, asleep: snap.asleep) }
    }

    /// Test helper: set the whole snapshot and notify (simulates a battery/LPM edge).
    func set(_ newSnap: PowerSnapshot) {
        lock.withLock { snap = newSnap }
        onChange?()
    }
}

/// Receiver that records emitted samples (verifies probe-gating, KTD12 fan-out).
private final class RecordingReceiver: SampleReceiver {
    private let lock = NSLock()
    private var samples: [Sample] = []
    func receive(_ sample: Sample) { lock.withLock { samples.append(sample) } }
    var all: [Sample] { lock.withLock { samples } }
}

final class PollingGovernorTests: XCTestCase {

    // MARK: - PURE state machine (precedence + sets)

    func testMenuBarOnlyIsTheIdleState() {
        let plan = CadencePlan.resolve(CadenceContext())
        XCTAssertEqual(plan.state, .menuBarOnly)
        XCTAssertEqual(plan.interval, Cadence.menuBar)
        XCTAssertEqual(plan.baseSet, .menuBar)
        XCTAssertTrue(plan.subCadenceSet.isEmpty, "detail/per-process paused when nothing visible")
    }

    func testPanelOpenMovesToDetailVisibleWithFullSetAtFasterInterval() {
        let ctx = CadenceContext(detailVisible: true, visibleMetrics: [.cpu, .sensors])
        let plan = CadencePlan.resolve(ctx)
        XCTAssertEqual(plan.state, .detailVisible)
        XCTAssertEqual(plan.interval, Cadence.detail)
        XCTAssertLessThan(plan.interval!, Cadence.menuBar, "panel raises cadence")
        XCTAssertTrue(plan.subCadenceSet.contains(.attribution), "CPU panel enables per-process")
        XCTAssertTrue(plan.subCadenceSet.contains(.sensors), "sensor panel enables sensor reads")
    }

    func testPanelClosedReturnsToMenuBarOnlyAndPausesDetail() {
        let open = CadencePlan.resolve(CadenceContext(detailVisible: true, visibleMetrics: [.cpu]))
        XCTAssertEqual(open.state, .detailVisible)
        let closed = CadencePlan.resolve(CadenceContext(detailVisible: false))
        XCTAssertEqual(closed.state, .menuBarOnly)
        XCTAssertTrue(closed.subCadenceSet.isEmpty)
    }

    func testLowPowerModeSelectsThrottledInterval() {
        let ctx = CadenceContext(throttled: true)
        let plan = CadencePlan.resolve(ctx)
        XCTAssertEqual(plan.state, .throttled)
        XCTAssertEqual(plan.interval, Cadence.throttled)
        XCTAssertGreaterThan(plan.interval!, Cadence.menuBar, "throttled is slower")
        XCTAssertTrue(plan.subCadenceSet.isEmpty, "no detail while throttled + no panel")
    }

    func testThrottleFlagDerivedFromBatteryLPMOrNoDisplay() {
        XCTAssertTrue(CadenceContext.throttleFlag(for: PowerSnapshot(onBattery: true)))
        XCTAssertTrue(CadenceContext.throttleFlag(for: PowerSnapshot(lowPowerMode: true)))
        XCTAssertTrue(CadenceContext.throttleFlag(for: PowerSnapshot(displayAttached: false)))
        XCTAssertFalse(CadenceContext.throttleFlag(for: PowerSnapshot()), "AC + display => not throttled")
    }

    func testSleepSuspendsCancellingTheTimer() {
        let plan = CadencePlan.resolve(CadenceContext(asleep: true))
        XCTAssertEqual(plan.state, .suspended)
        XCTAssertNil(plan.interval, "suspended cancels the timer (no interval)")
        XCTAssertTrue(plan.baseSet.isEmpty)
        XCTAssertTrue(plan.subCadenceSet.isEmpty)
    }

    // MARK: - Precedence (KTD3): overlapping transitions

    func testBatteryPlusPanelOpenRaisesCadenceForVisibleMetricAE3() {
        // AE3: battery + LPM + panel open => DetailVisible wins over Throttled for the visible
        // metric; cadence is raised and per-process runs even on battery.
        let ctx = CadenceContext(detailVisible: true, visibleMetrics: [.cpu],
                                 throttled: true)
        let plan = CadencePlan.resolve(ctx)
        XCTAssertEqual(plan.state, .detailVisible, "panel beats throttle (AE3)")
        XCTAssertEqual(plan.interval, Cadence.detail, "cadence raised despite battery")
        XCTAssertTrue(plan.subCadenceSet.contains(.attribution),
                      "per-process runs for the visible metric even under battery")
    }

    func testNonVisibleDetailStaysThrottledWhileVisibleMetricRuns() {
        // Only the CPU panel is open: per-process (attribution) runs, but sensors stay paused
        // — non-visible detail collection is NOT raised (KTD3).
        let ctx = CadenceContext(detailVisible: true, visibleMetrics: [.cpu], throttled: true)
        let plan = CadencePlan.resolve(ctx)
        XCTAssertTrue(plan.subCadenceSet.contains(.attribution))
        XCTAssertFalse(plan.subCadenceSet.contains(.sensors), "non-visible sensor stays paused")
    }

    func testSleepOverridesPanelOpenAndThrottle() {
        let ctx = CadenceContext(detailVisible: true, visibleMetrics: [.cpu, .sensors],
                                 throttled: true, asleep: true)
        XCTAssertEqual(CadencePlan.resolve(ctx).state, .suspended, "sleep overrides everything")
    }

    // MARK: - Leeway (R11)

    func testLeewayIsAtLeastTenPercentAndLargerWhenThrottled() {
        let menuBar = CadencePlan.resolve(CadenceContext())
        XCTAssertEqual(menuBar.leeway, menuBar.interval! * 0.1, accuracy: 1e-9)
        let throttled = CadencePlan.resolve(CadenceContext(throttled: true))
        XCTAssertGreaterThan(throttled.leeway, throttled.interval! * 0.1,
                             "throttled leeway is looser than 10% to coalesce wakeups")
    }

    // MARK: - Live governor with fakes

    private func makeGovernor(power: FakePowerContext,
                              timer: FakeTimer,
                              sink: SampleSink,
                              probe: SensorProbe?) throws -> PollingGovernor {
        let queue = DispatchQueue(label: "test.governor")
        return PollingGovernor(
            sink: sink,
            power: power,
            cpu: CPUCollector(),
            memory: MemoryCollector(),
            disk: DiskCollector(),
            network: NetworkCollector(),
            attribution: try ProcessAttributionCollector(foregroundProvider: { "Xcode" }),
            sensorProbe: probe,
            queue: queue,
            timer: timer
        )
    }

    func testStartSchedulesAtMenuBarCadence() throws {
        let timer = FakeTimer()
        let power = FakePowerContext()
        let gov = try makeGovernor(power: power, timer: timer, sink: SampleSink(), probe: nil)
        gov.start()
        XCTAssertEqual(gov.currentState, .menuBarOnly)
        XCTAssertEqual(timer.lastInterval, Cadence.menuBar)
        XCTAssertTrue(timer.isRunning)
    }

    func testPanelOpenThenCloseTransitionsLiveGovernor() throws {
        let timer = FakeTimer()
        let gov = try makeGovernor(power: FakePowerContext(), timer: timer, sink: SampleSink(), probe: nil)
        gov.start()
        gov.setDetailVisible(true, metrics: [.cpu])
        XCTAssertEqual(gov.currentState, .detailVisible)
        XCTAssertEqual(gov.plan.interval, Cadence.detail)
        gov.setDetailVisible(false)
        XCTAssertEqual(gov.currentState, .menuBarOnly)
        XCTAssertTrue(gov.plan.subCadenceSet.isEmpty)
    }

    func testLowPowerModeThenRestoreTogglesThrottle() throws {
        let timer = FakeTimer()
        let power = FakePowerContext()
        let gov = try makeGovernor(power: power, timer: timer, sink: SampleSink(), probe: nil)
        gov.start()
        XCTAssertEqual(gov.currentState, .menuBarOnly)

        power.set(PowerSnapshot(lowPowerMode: true))
        XCTAssertEqual(gov.currentState, .throttled)
        XCTAssertEqual(gov.plan.interval, Cadence.throttled)

        power.set(PowerSnapshot()) // AC + display restored
        XCTAssertEqual(gov.currentState, .menuBarOnly)
    }

    func testSleepCancelsTimerAndIsNeverLeftRunningWhileSuspended() throws {
        let timer = FakeTimer()
        let gov = try makeGovernor(power: FakePowerContext(), timer: timer, sink: SampleSink(), probe: nil)
        gov.start()
        _ = gov.plan // barrier: drain the async start() onto the serial queue
        XCTAssertTrue(timer.isRunning)
        gov.systemWillSleep()
        XCTAssertEqual(gov.currentState, .suspended)
        XCTAssertFalse(timer.isRunning, "timer must not run while suspended (energy-leak guard)")
    }

    func testWakeResumesAndFiresCatchUpHookExactlyOnce() throws {
        let timer = FakeTimer()
        let gov = try makeGovernor(power: FakePowerContext(), timer: timer, sink: SampleSink(), probe: nil)
        let wakeCount = WakeCounter()
        gov.onWake = { wakeCount.increment() }
        gov.start()
        gov.systemWillSleep()
        gov.systemDidWake()
        XCTAssertEqual(gov.currentState, .menuBarOnly, "wake resumes")
        XCTAssertTrue(timer.isRunning)
        // Drain the serial queue so the async onWake has run.
        gov.plan // synchronous queue hop acts as a barrier
        XCTAssertEqual(wakeCount.value, 1, "catch-up fires exactly once per wake")
    }

    func testScreenWakeResumesButDoesNotFireSystemCatchUp() throws {
        let timer = FakeTimer()
        let gov = try makeGovernor(power: FakePowerContext(), timer: timer, sink: SampleSink(), probe: nil)
        let wakeCount = WakeCounter()
        gov.onWake = { wakeCount.increment() }
        gov.start()
        gov.screensDidSleep()
        XCTAssertEqual(gov.currentState, .suspended)
        gov.screensDidWake()
        XCTAssertEqual(gov.currentState, .menuBarOnly)
        _ = gov.plan
        XCTAssertEqual(wakeCount.value, 0, "screen wake keeps app awake; no store catch-up")
    }

    // MARK: - Probe-gated ingest + KTD12 emit

    func testTickEmitsOneSampleWithoutSensorsWhenProbeUnresolved() throws {
        let timer = FakeTimer()
        let sink = SampleSink()
        let receiver = RecordingReceiver()
        sink.register(receiver)
        let gov = try makeGovernor(power: FakePowerContext(), timer: timer, sink: sink, probe: nil)
        gov.start()
        // Open a sensor panel so detail would include sensors, but probe is nil (pre-probe).
        gov.setDetailVisible(true, metrics: [.sensors, .cpu])
        _ = gov.plan // barrier: ensure start()+setDetailVisible scheduled the timer
        // Fire enough ticks to cross the sub-cadence gate. tick() runs synchronously on the
        // caller (the fake timer fires inline), but it touches queue-confined state — fire it
        // on the governor queue by going through the scheduled handler.
        for _ in 0..<(Cadence.detailSubCadenceFactor) { timer.fire() }
        _ = gov.plan // barrier

        XCTAssertFalse(receiver.all.isEmpty, "ticks emit samples (KTD12 fan-out)")
        XCTAssertTrue(receiver.all.allSatisfy { $0.sensors == nil },
                      "pre-probe sensor ticks are dropped, not emitted as NULL")
    }

    func testTimerReschedulesOnCadenceChangeAndCancelsOnSuspend() throws {
        let timer = FakeTimer()
        let gov = try makeGovernor(power: FakePowerContext(), timer: timer, sink: SampleSink(), probe: nil)
        gov.start()
        _ = gov.plan // barrier: drain async start()
        let afterStart = timer.scheduleCount
        XCTAssertGreaterThanOrEqual(afterStart, 1)

        gov.setDetailVisible(true, metrics: [.cpu]) // reschedule (faster interval)
        _ = gov.plan
        XCTAssertGreaterThan(timer.scheduleCount, afterStart, "cadence change reschedules")

        let beforeSleep = timer.cancelCount
        gov.systemWillSleep()
        _ = gov.plan
        XCTAssertGreaterThan(timer.cancelCount, beforeSleep, "suspend cancels")
        XCTAssertFalse(timer.isRunning)
    }
}

/// Thread-safe counter for the async `onWake` hook.
private final class WakeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
