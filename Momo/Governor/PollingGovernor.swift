//
//  PollingGovernor.swift
//  Central polling governor: one timer drives every collector on a coalesced wakeup (KTD3,
//  KTD11, KTD12, R10, R11).
//
//  Design (KTD3):
//   - ONE `DispatchSourceTimer` on a `.utility` serial queue. That queue is the collectors'
//     confinement domain (KTD11): every collector is instantiated and called only here, so
//     their mutable delta-math state is race-free without locks.
//   - The wakeup fires at the *fastest currently-required* interval; slower collectors are
//     TICK-GATED (they skip wakeups to hit their slower effective rate). Sensors + per-process
//     run on a slower sub-cadence than CPU/network.
//   - Each tick: call the due collectors, assemble ONE immutable `Sample`, `sink.emit(sample)`.
//     The governor holds only the `SampleSink` (KTD12) — never the store / ring buffer.
//   - Cadence is decided by a PURE value type (`CadenceContext` -> `CadencePlan`) so the policy
//     is unit-testable with a fake clock; the live timer just applies the plan.
//
//  Precedence (KTD3): Suspended > DetailVisible(for visible metrics) > Throttled > MenuBarOnly.
//   - Suspended (system / screen sleep) cancels the timer entirely — nothing is sampled.
//   - DetailVisible raises cadence AND enables per-process / sensor detail for the visible
//     metrics EVEN under battery/LPM (AE3 — an open panel is an explicit investigation
//     request); non-visible collection stays throttled.
//   - Throttled (battery / LPM / no display) slows everything when no panel is open.
//
//  Probe-gated ingest: sensor ticks are dropped (not emitted as a NULL sensor reading) until
//  `SensorProbe` has resolved, so a later absent sensor never ambiguously means "probe pending".
//  The probe is resolved in `SensorProbe.init`, so once a probe is injected it is ready.
//
//  Concurrency (KTD11): all mutable governor state lives on `queue`; public methods hop onto
//  `queue` so the app delegate's main-thread closures can call them safely. The cadence value
//  types are `Sendable`. The one main-actor hop (publishing to the UI live model) is a later
//  unit's concern — here we only `sink.emit`.
//
import Foundation

// MARK: - Cadence policy (PURE, Sendable, unit-tested)

/// The four cadence regimes of the state machine (HTD diagram). Pure descriptive state.
enum CadenceState: Sendable, Equatable {
    case menuBarOnly
    case detailVisible
    case throttled
    case suspended
}

/// Which subsystems a tick should sample. CPU/memory/disk/network are the "menu-bar" set
/// (cheap, always run when not suspended); sensors and per-process are the "detail" set that
/// runs on a slower sub-cadence and is paused when no panel is visible (KTD3).
struct CollectorSet: Sendable, Equatable, OptionSet {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    static let cpu        = CollectorSet(rawValue: 1 << 0)
    static let memory     = CollectorSet(rawValue: 1 << 1)
    static let disk       = CollectorSet(rawValue: 1 << 2)
    static let network    = CollectorSet(rawValue: 1 << 3)
    static let sensors    = CollectorSet(rawValue: 1 << 4)
    static let attribution = CollectorSet(rawValue: 1 << 5)

    /// Cheap system metrics that run on every non-suspended wakeup.
    static let menuBar: CollectorSet = [.cpu, .memory, .disk, .network]
    /// Slower, costlier detail metrics (sub-cadence; paused when nothing is visible).
    static let detail: CollectorSet = [.sensors, .attribution]
    static let all: CollectorSet = [.menuBar, .detail]
}

/// Cadence intervals (seconds). Directional targets per HTD — tuned against the R11 budget.
enum Cadence {
    /// Faster base cadence while a drill-down panel is open (AE3).
    static let detail: TimeInterval = 1
    /// Default menu-bar-only base cadence.
    static let menuBar: TimeInterval = 2
    /// Throttled base cadence on battery / LPM / no display (R10).
    static let throttled: TimeInterval = 5
    /// Sub-cadence multiplier: sensors + per-process run every Nth base wakeup. Keeps the
    /// costly scans off the fast path (KTD3 "slower sub-cadence than CPU/network").
    static let detailSubCadenceFactor = 3
}

/// The immutable inputs to the cadence decision. Folded from the `PowerSnapshot`, the panel
/// visibility, and the sleep state. Pure — no live sources — so the policy is fully testable.
struct CadenceContext: Sendable, Equatable {
    /// A drill-down panel is open (R3/R4); raises cadence + enables detail for visible metrics.
    var detailVisible: Bool
    /// The metrics whose panels are visible (drives which detail collectors run under AE3).
    var visibleMetrics: CollectorSet
    /// Battery / Low Power Mode / no attached display — the Throttled trigger (R10).
    var throttled: Bool
    /// System or screen sleep — the Suspended trigger; overrides everything (KTD3).
    var asleep: Bool

    init(detailVisible: Bool = false,
         visibleMetrics: CollectorSet = [],
         throttled: Bool = false,
         asleep: Bool = false) {
        self.detailVisible = detailVisible
        self.visibleMetrics = visibleMetrics
        self.throttled = throttled
        self.asleep = asleep
    }

    /// Derive `throttled` + `asleep` from a power snapshot (battery OR LPM OR no display).
    static func throttleFlag(for power: PowerSnapshot) -> Bool {
        power.onBattery || power.lowPowerMode || !power.displayAttached
    }
}

/// The pure output of the cadence state machine. The base wakeup interval, the resolved state,
/// the always-on (menu-bar) collector set, and the detail set that runs on the sub-cadence.
struct CadencePlan: Sendable, Equatable {
    let state: CadenceState
    /// Base wakeup interval (the fastest currently-required rate); `nil` when Suspended.
    let interval: TimeInterval?
    /// Collectors that run on every base wakeup.
    let baseSet: CollectorSet
    /// Collectors that run on the slower sub-cadence (every Nth base wakeup). Empty when no
    /// panel is visible (detail paused — KTD3) or when suspended.
    let subCadenceSet: CollectorSet

    /// The pure cadence state machine (KTD3 precedence: Suspended > DetailVisible > Throttled >
    /// MenuBarOnly). This is the single source of truth tests assert against.
    static func resolve(_ c: CadenceContext) -> CadencePlan {
        // Suspended wins absolutely — nothing is sampled (timer cancelled by the live governor).
        if c.asleep {
            return CadencePlan(state: .suspended, interval: nil, baseSet: [], subCadenceSet: [])
        }

        // DetailVisible: an open panel is an explicit investigation request, so it raises
        // cadence and enables detail for the *visible* metrics even under battery/LPM (AE3).
        if c.detailVisible {
            // Detail collectors gated by what is actually visible: sensors only if a sensor
            // panel is open, per-process only for a subsystem that supports attribution.
            var detail: CollectorSet = []
            if c.visibleMetrics.contains(.sensors) { detail.insert(.sensors) }
            if !c.visibleMetrics.intersection([.cpu, .memory, .disk]).isEmpty {
                detail.insert(.attribution)
            }
            return CadencePlan(state: .detailVisible,
                               interval: Cadence.detail,
                               baseSet: .menuBar,
                               subCadenceSet: detail)
        }

        // Throttled: battery / LPM / no display with no panel open — slow everything, no detail.
        if c.throttled {
            return CadencePlan(state: .throttled,
                               interval: Cadence.throttled,
                               baseSet: .menuBar,
                               subCadenceSet: [])
        }

        // MenuBarOnly: the steady idle state. Cheap metrics only; detail paused (KTD3).
        return CadencePlan(state: .menuBarOnly,
                           interval: Cadence.menuBar,
                           baseSet: .menuBar,
                           subCadenceSet: [])
    }

    /// Timer leeway: ≥10% of the interval, much larger when throttled (R11 — Energy Impact is
    /// dominated by wakeups; loose leeway lets the OS coalesce them).
    var leeway: TimeInterval {
        guard let interval else { return 0 }
        switch state {
        case .throttled: return interval * 0.5
        default:         return interval * 0.1
        }
    }
}

// MARK: - Timer abstraction (injectable so tests count create/cancel without wall-clock)

/// One coalesced wakeup source. Abstracted so tests can drive ticks deterministically and
/// COUNT create/cancel (guards the energy-leak "forgot to invalidate" bug — KTD3 integration
/// test) without relying on a real `DispatchSourceTimer` firing on wall time.
protocol GovernorTimer: AnyObject {
    /// (Re)schedule the wakeup at `interval` (seconds) with `leeway`, invoking `handler` on
    /// each fire. Replaces any existing schedule.
    func schedule(interval: TimeInterval, leeway: TimeInterval, handler: @escaping () -> Void)
    /// Cancel the wakeup (Suspended). Must leave nothing running — verified by the test counter.
    func cancel()
}

/// Live timer: a `DispatchSourceTimer` on the governor's serial queue.
final class DispatchGovernorTimer: GovernorTimer {
    private let queue: DispatchQueue
    private var source: DispatchSourceTimer?

    init(queue: DispatchQueue) { self.queue = queue }

    func schedule(interval: TimeInterval, leeway: TimeInterval, handler: @escaping () -> Void) {
        cancel()
        let src = DispatchSource.makeTimerSource(queue: queue)
        // Second-aligned start: round up to the next whole second so ticks land on the second.
        let now = Date().timeIntervalSince1970
        let firstFire = (now.rounded(.down) + 1) - now
        src.schedule(deadline: .now() + max(0, firstFire),
                     repeating: interval,
                     leeway: .nanoseconds(Int(leeway * 1_000_000_000)))
        src.setEventHandler(handler: handler)
        source = src
        src.resume()
    }

    func cancel() {
        source?.cancel()
        source = nil
    }
}

// MARK: - Governor

/// Drives all collectors on one coalesced wakeup at a context-determined cadence, assembling
/// one immutable `Sample` per tick and handing it to the sink (KTD12). Owns the collectors and
/// confines them to its serial queue (KTD11).
///
/// `@unchecked Sendable` is the honest statement of the KTD11 contract: the governor holds
/// non-`Sendable` collectors and mutable cadence state, but every access to that state happens
/// on `queue` (public methods hop onto it; the timer handler runs on it). The reference itself
/// is safe to pass into the `@Sendable` `queue.async` / timer closures because all the work it
/// does there is queue-confined. The compiler can't prove the confinement, so we assert it.
final class PollingGovernor: @unchecked Sendable {
    private let queue: DispatchQueue
    private let timer: GovernorTimer
    private let sink: SampleSink

    // Collectors — confined to `queue`, owned solely by the governor (KTD11).
    private let cpu: CPUCollector
    private let memory: MemoryCollector
    private let disk: DiskCollector
    private let network: NetworkCollector
    private let attribution: ProcessAttributionCollector
    private let sensorProbe: SensorProbe?      // nil until probe resolves (probe-gated ingest)
    private let power: PowerContextProtocol

    // Mutable cadence state — touched only on `queue`.
    private var context = CadenceContext()
    private var currentPlan: CadencePlan = .resolve(CadenceContext())
    /// Monotonic tick counter for sub-cadence gating (sensors/per-process every Nth wakeup).
    private var tickCount: UInt64 = 0
    private var running = false

    /// Hook the store's catch-up pass (U6) connects to. Fired once per wake (KTD3 / R5 catch-up).
    /// The governor does NOT depend on the store — the owner wires this.
    var onWake: (() -> Void)?

    /// - Parameters injected so tests substitute fakes. `sensorProbe` is `nil` to simulate
    ///   pre-probe (sensor ticks dropped); a resolved probe enables sensor ingest.
    init(
        sink: SampleSink,
        power: PowerContextProtocol,
        cpu: CPUCollector,
        memory: MemoryCollector,
        disk: DiskCollector,
        network: NetworkCollector,
        attribution: ProcessAttributionCollector,
        sensorProbe: SensorProbe?,
        queue: DispatchQueue = DispatchQueue(label: "com.florianriquelme.momo.governor", qos: .utility),
        timer: GovernorTimer? = nil
    ) {
        self.sink = sink
        self.power = power
        self.cpu = cpu
        self.memory = memory
        self.disk = disk
        self.network = network
        self.attribution = attribution
        self.sensorProbe = sensorProbe
        self.queue = queue
        self.timer = timer ?? DispatchGovernorTimer(queue: queue)
    }

    // MARK: - Lifecycle

    /// Start collecting. Folds the current power snapshot into the context and applies the plan.
    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.running = true
            self.power.onChange = { [weak self] in self?.powerChanged() }
            self.refreshContextFromPower()
            self.applyPlan()
        }
    }

    /// Stop entirely (app teardown). Cancels the timer.
    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.timer.cancel()
        }
    }

    // MARK: - Inputs (called by the app delegate's main-thread closures; hop onto `queue`)

    /// Panel visibility from the drill-down UI (U8). `metrics` is which metric panels are open
    /// (drives AE3 per-visible-metric detail). Empty `metrics` with `visible == false` returns
    /// to MenuBarOnly and pauses detail/per-process collection (KTD3).
    func setDetailVisible(_ visible: Bool, metrics: CollectorSet = []) {
        queue.async { [weak self] in
            guard let self else { return }
            self.context.detailVisible = visible
            self.context.visibleMetrics = visible ? metrics : []
            self.applyPlan()
        }
    }

    /// System sleep — Suspended (timer cancelled; nothing sampled). Wired from
    /// `AppDelegate.onWillSleep`.
    func systemWillSleep() {
        queue.async { [weak self] in
            guard let self else { return }
            self.power.updateSleepState(asleep: true)
            self.context.asleep = true
            self.applyPlan()
        }
    }

    /// System wake — resume and fire the catch-up hook EXACTLY ONCE. Resets all collectors
    /// (a delta across a sleep gap is garbage — KTD3 / MetricCollector.reset()). Wired from
    /// `AppDelegate.onDidWake`.
    func systemDidWake() {
        queue.async { [weak self] in
            guard let self else { return }
            self.power.updateSleepState(asleep: false)
            self.context.asleep = false
            self.resetCollectors()
            self.applyPlan()
            self.onWake?()
        }
    }

    /// Screen sleep — Suspended (same as system sleep for cadence: nothing visible to monitor).
    func screensDidSleep() {
        queue.async { [weak self] in
            guard let self else { return }
            self.context.asleep = true
            self.applyPlan()
        }
    }

    /// Screen wake — resume; reset collectors so the post-wake delta isn't computed across the
    /// gap. Does NOT fire `onWake` (that is the system-sleep catch-up; screen sleep keeps the
    /// app awake so no store catch-up pass is needed).
    func screensDidWake() {
        queue.async { [weak self] in
            guard let self else { return }
            self.context.asleep = false
            self.resetCollectors()
            self.applyPlan()
        }
    }

    // MARK: - Plan application (on `queue`)

    private func powerChanged() {
        queue.async { [weak self] in
            guard let self else { return }
            self.refreshContextFromPower()
            self.applyPlan()
        }
    }

    /// Fold the live power snapshot into the cadence context. Sleep is also tracked from the
    /// snapshot so a snapshot-sourced sleep edge is honored even if a closure was missed.
    private func refreshContextFromPower() {
        let snap = power.snapshot()
        context.throttled = CadenceContext.throttleFlag(for: snap)
        context.asleep = context.asleep || snap.asleep
    }

    /// Resolve the plan and reconcile the timer: schedule at the new interval, or cancel when
    /// Suspended. Never leaves the timer running while Suspended (the energy-leak guard).
    private func applyPlan() {
        guard running else { timer.cancel(); return }
        let plan = CadencePlan.resolve(context)
        currentPlan = plan

        guard let interval = plan.interval else {
            // Suspended: cancel and stop. tickCount left as-is; resume re-bases collectors.
            timer.cancel()
            return
        }

        timer.schedule(interval: interval, leeway: plan.leeway) { [weak self] in
            self?.tick()
        }
    }

    private func resetCollectors() {
        cpu.reset()
        memory.reset()
        disk.reset()
        network.reset()
        attribution.reset()
        tickCount = 0
    }

    // MARK: - Tick (on `queue`) — assemble ONE Sample and emit (KTD12)

    /// Run the due collectors for this wakeup, compose one immutable `Sample`, and emit it to
    /// the sink. Exposed `internal` so tests drive a tick deterministically via the fake timer.
    func tick() {
        tickCount &+= 1
        let plan = currentPlan
        guard plan.interval != nil else { return } // suspended; defensive

        let now = Date()
        let runDetail = !plan.subCadenceSet.isEmpty
            && tickCount % UInt64(Cadence.detailSubCadenceFactor) == 0

        // --- Menu-bar (base) metrics: cheap, every wakeup. A failing collector omits its
        //     subsystem this tick (KTD5/R12: absence, never a fabricated zero). ---
        let cpuSample: CPUSample?     = plan.baseSet.contains(.cpu)     ? try? cpu.sample()        : nil
        let memSample: MemorySample?  = plan.baseSet.contains(.memory)  ? try? memory.sample()     : nil
        let diskSample: DiskSample?   = plan.baseSet.contains(.disk)    ? try? disk.sample(now: now) : nil
        let netSample: NetworkSample? = plan.baseSet.contains(.network) ? try? network.sample(now: now) : nil

        // --- Detail (sub-cadence) metrics: only on gated ticks while visible. ---
        var sensorSample: SensorSample?
        var attributionSample: AttributionSample?
        if runDetail {
            // Probe-gated: drop the sensor tick entirely until the probe has resolved, so a
            // NULL never ambiguously means "probe pending" vs "sensor absent".
            if plan.subCadenceSet.contains(.sensors), let probe = sensorProbe {
                sensorSample = probe.read()
            }
            if plan.subCadenceSet.contains(.attribution) {
                attributionSample = try? attribution.sample(at: now)
            }
        }

        // Correlated state always carries the live power snapshot (KTD11: U4 records it).
        let correlated = attribution.correlatedState(power: power.snapshot())

        let sample = Sample(
            timestamp: now,
            cpu: cpuSample,
            memory: memSample,
            disk: diskSample,
            network: netSample,
            sensors: sensorSample,
            attribution: attributionSample,
            context: correlated
        )
        sink.emit(sample)
    }

    // MARK: - Test introspection (read on `queue`)

    /// The current resolved cadence state. Synchronously hops to `queue` for deterministic
    /// assertions in tests.
    var currentState: CadenceState {
        queue.sync { currentPlan.state }
    }

    /// The current resolved plan (interval, sets). Synchronous for tests.
    var plan: CadencePlan {
        queue.sync { currentPlan }
    }
}
