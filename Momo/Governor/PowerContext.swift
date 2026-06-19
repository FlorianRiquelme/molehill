//
//  PowerContext.swift
//  Power-state observation feeding the governor's cadence and U4's correlated state (KTD11, R10).
//
//  Vends an immutable `Sendable` `PowerSnapshot` (defined in Core/Sample.swift) read by two
//  consumers: the governor, which folds it into the cadence state machine (battery / Low Power
//  Mode / no-display => Throttled), and `ProcessAttributionCollector.correlatedState(power:)`,
//  which records it alongside per-process attribution. The single immutable value both consume
//  is the KTD11 power surface.
//
//  Signal sources (R10):
//   - Low Power Mode: the `ProcessInfo.processInfo` *singleton* (NEVER a fresh `ProcessInfo()`
//     — a fresh instance corrupts `isLowPowerModeEnabled`), refreshed on
//     `NSProcessInfoPowerStateDidChange`.
//   - Battery vs AC: `IOPSNotificationCreateRunLoopSource` + `IOPSCopyPowerSourcesInfo`.
//   - Display-attached + asleep: fed in from the app delegate's sleep/wake signals (the
//     governor forwards them) — there is no clean privilege-free polling API, and the
//     sleep/wake notifications are the authoritative edge.
//
//  Concurrency: the live `PowerContext` guards its mutable snapshot behind a lock so
//  `snapshot()` is safe to call from the governor's serial queue while the run-loop callbacks
//  mutate it on the main thread. The cadence logic that *uses* the snapshot is a pure value
//  type (`CadenceContext` in PollingGovernor.swift) so it is testable without any live source.
//
import Foundation
import IOKit.ps
import os

/// The power-state surface the governor reads. A protocol so `PollingGovernor` can be unit
/// tested against a fake that returns any `PowerSnapshot` without IOKit / `ProcessInfo`.
protocol PowerContextProtocol: AnyObject {
    /// The current immutable power snapshot. Safe to call from the governor's serial queue.
    func snapshot() -> PowerSnapshot
    /// Update the display/sleep half of the snapshot from the app delegate's sleep/wake edges.
    /// (Battery/LPM are observed internally; display/asleep are pushed in.)
    func updateSleepState(asleep: Bool)
    func updateDisplayAttached(_ attached: Bool)
    /// Called when any internally-observed signal (battery/LPM) changes, so the governor can
    /// re-evaluate cadence promptly rather than waiting for the next tick.
    var onChange: (@Sendable () -> Void)? { get set }
}

/// Live power context. Sources Low Power Mode + battery/AC itself and accepts display/asleep
/// edges from the governor. Mutable snapshot is lock-guarded (callbacks fire on the main
/// thread; `snapshot()` is read from the governor queue).
final class PowerContext: PowerContextProtocol, @unchecked Sendable {
    private let state: OSAllocatedUnfairLock<PowerSnapshot>
    private var powerSourceRunLoopSource: CFRunLoopSource?

    var onChange: (@Sendable () -> Void)?

    init() {
        // Seed from the live singletons. NEVER `ProcessInfo()` (KTD/U5: corrupts the result).
        let lpm = ProcessInfo.processInfo.isLowPowerModeEnabled
        let onBattery = Self.readOnBattery()
        state = OSAllocatedUnfairLock(initialState: PowerSnapshot(
            onBattery: onBattery,
            lowPowerMode: lpm,
            displayAttached: true,
            asleep: false
        ))
    }

    /// Begin observing Low Power Mode and battery/AC. Must be called once at startup; the
    /// callbacks dispatch back to the governor via `onChange`.
    func start() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(powerStateChanged),
            name: .NSProcessInfoPowerStateDidChange,
            object: nil
        )
        installPowerSourceObserver()
    }

    deinit {
        // Safe for the singleton (app lifetime), but make the invariant explicit so a future
        // non-singleton use (e.g. a unit test constructing PowerContext) doesn't fire the IOPS
        // callback against a freed pointer.
        if let source = powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        NotificationCenter.default.removeObserver(self)
    }

    func snapshot() -> PowerSnapshot { state.withLock { $0 } }

    func updateSleepState(asleep: Bool) {
        let current = snapshot()
        store(PowerSnapshot(onBattery: current.onBattery, lowPowerMode: current.lowPowerMode,
                            displayAttached: current.displayAttached, asleep: asleep))
    }

    func updateDisplayAttached(_ attached: Bool) {
        let current = snapshot()
        store(PowerSnapshot(onBattery: current.onBattery, lowPowerMode: current.lowPowerMode,
                            displayAttached: attached, asleep: current.asleep))
    }

    // MARK: - Internal signal handling

    @objc private func powerStateChanged() {
        let lpm = ProcessInfo.processInfo.isLowPowerModeEnabled
        let onBattery = Self.readOnBattery()
        let current = snapshot()
        store(PowerSnapshot(onBattery: onBattery, lowPowerMode: lpm,
                            displayAttached: current.displayAttached, asleep: current.asleep))
    }

    /// `true` when the active power source is the internal battery (not AC). Defaults to `false`
    /// (AC) on desktops / unknown — a desktop is never throttled for "on battery".
    private static func readOnBattery() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                as? [String: Any],
                  let providing = desc[kIOPSPowerSourceStateKey] as? String
            else { continue }
            if providing == kIOPSBatteryPowerValue { return true }
        }
        return false
    }

    private func installPowerSourceObserver() {
        // IOPS run-loop source: fires whenever a power source changes (AC<->battery, %).
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<PowerContext>.fromOpaque(ctx).takeUnretainedValue()
            me.powerStateChanged()
        }, context)?.takeRetainedValue() else { return }
        powerSourceRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    /// Store a new snapshot; fire `onChange` only if it actually differs (so the governor
    /// re-evaluates cadence on a real edge, not a redundant notification).
    private func store(_ newSnap: PowerSnapshot) {
        let changed = state.withLock { current -> Bool in
            guard current != newSnap else { return false }
            current = newSnap
            return true
        }
        if changed { onChange?() }
    }
}
