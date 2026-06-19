//
//  MomoServices.swift
//  Composition root: builds and owns the whole live pipeline once (this app has exactly one of
//  everything). Wires the KTD12 fan-out — governor -> SampleSink -> {RingBuffer (live path),
//  RecordingStore (recording path)} — and the KTD11 main-actor hop into the observable model.
//
//  The governor depends only on the sink (KTD12 one-way dependency); the store/ring are
//  registered as sink receivers here, not held by the governor.
//
import Foundation

@MainActor
final class MomoServices {
    static let shared = MomoServices()

    let ring: RingBuffer
    let live: LiveModel
    let selection: MetricSelection
    let power: PowerContext
    let store: RecordingStore?
    let governor: PollingGovernor

    private var started = false

    private init() {
        let ring = RingBuffer()
        self.ring = ring
        self.live = LiveModel(ring: ring)
        self.selection = MetricSelection()
        self.power = PowerContext()

        // Per-process attribution refuses to construct on libproc struct-stride drift (KTD5).
        // That is a should-never-happen toolchain mismatch; trapping here is the intended
        // "refuse to run rather than record corrupt attribution" behavior.
        let attribution = try! ProcessAttributionCollector()

        // Recording store at the standard Application Support location (KTD4b). If it can't open
        // we still run live monitoring (recording is best-effort, not a launch blocker).
        let store = (try? RecordingStore.defaultURL()).flatMap { try? RecordingStore(url: $0) }
        self.store = store

        let sink = SampleSink()
        sink.register(ring)
        if let store { sink.register(store) }

        self.governor = PollingGovernor(
            sink: sink,
            power: power,
            cpu: CPUCollector(),
            memory: MemoryCollector(),
            disk: DiskCollector(),
            network: NetworkCollector(),
            attribution: attribution,
            sensorProbe: Self.makeSensorProbe()
        )
        governor.onWake = { [weak store] in try? store?.runCatchUp() }
    }

    /// Start observers, run launch catch-up (R5), and begin collecting. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        power.start()
        ForegroundAppTracker.shared.start()
        try? store?.runCatchUp()
        governor.start()
    }

    /// Durability flush on graceful exit (applicationWillTerminate; KTD2 bound).
    func flush() {
        store?.flushPending()
    }

    /// HID probe on Apple Silicon (live), SMC on Intel (best-effort, OQ9). Nil if no backend
    /// resolves — sensor ticks are then dropped by the governor (probe-gated ingest).
    private static func makeSensorProbe() -> SensorProbe? {
        let platform = SensorArchitecture.detect()
        let backend: SensorReadingBackend?
        switch platform {
        case .appleSilicon: backend = HIDSensorBackend()
        case .intel:        backend = SMCSensorBackend()
        }
        guard let backend else { return nil }
        return SensorProbe(platform: platform, backend: backend)
    }
}
