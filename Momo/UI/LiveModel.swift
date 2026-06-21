//
//  LiveModel.swift
//  The in-memory live path (KTD12): raw per-tick samples for the menu-bar readout and the
//  drill-down live graph — kept separate from the recording store (which holds bucket
//  aggregates) so the menu bar never over-notifies off DB writes.
//
//  Concurrency (KTD11): `RingBuffer` receives on the governor's collection queue and performs
//  the single main-actor hop into `LiveModel` (which is `@MainActor @Observable`, hence Sendable
//  and safe to drive SwiftUI).
//
import Foundation
import os

/// Bounded ring of raw per-tick `Sample`s. A `SampleReceiver` registered on the governor's
/// sink (KTD12). Feeds the menu-bar readout (`latest`) and the drill-down live graph
/// (`recent`). Thread-safe; `onSample` fires on the governor queue for each tick.
final class RingBuffer: SampleReceiver, @unchecked Sendable {
    private let storage: OSAllocatedUnfairLock<[Sample]>
    private let capacity: Int

    /// Invoked on the governor's collection queue for every received sample. The owner hops to
    /// the main actor here (the single KTD11 main-actor hop).
    var onSample: (@Sendable (Sample) -> Void)?

    /// - Parameter capacity: max raw samples retained (~30 min at 1s cadence by default).
    init(capacity: Int = 1800) {
        self.capacity = capacity
        self.storage = OSAllocatedUnfairLock(initialState: [])
    }

    func receive(_ sample: Sample) {
        storage.withLock { buffer in
            buffer.append(sample)
            if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }
        }
        onSample?(sample)
    }

    var latest: Sample? { storage.withLock { $0.last } }

    /// The most recent `count` samples, oldest first (for the live graph's rolling window).
    func recent(_ count: Int) -> [Sample] { storage.withLock { Array($0.suffix(count)) } }
}

/// UI-facing observable model. Holds the latest sample (menu-bar readout) and exposes the ring
/// for the drill-down. Updated only on new data (not a render clock) per R2.
@MainActor
@Observable
final class LiveModel {
    private(set) var latest: Sample?
    /// Bumped each tick so SwiftUI views observing the rolling window re-render (the ring's
    /// internal array isn't itself observable).
    private(set) var tick: UInt64 = 0

    @ObservationIgnored let ring: RingBuffer

    init(ring: RingBuffer) {
        self.ring = ring
        ring.onSample = { [weak self] sample in
            // Single main-actor hop (KTD11): governor queue -> main actor.
            Task { @MainActor [weak self] in self?.ingest(sample) }
        }
    }

    private func ingest(_ sample: Sample) {
        latest = sample
        tick &+= 1
    }
}
