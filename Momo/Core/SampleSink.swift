//
//  SampleSink.swift
//  Single fan-out point for assembled samples (KTD12).
//
//  The assembler produces one immutable `Sample` per tick and hands it here; the sink
//  delivers that same value to every registered receiver (the in-memory ring buffer and
//  the recording store, added in later units). The load-bearing rule is the *one-way
//  dependency*: the governor depends only on "produce a Sample and hand it off" and holds
//  a reference to the sink — never to the store or ring buffer directly.
//
//  Concrete by design. A `SampleSink` *protocol* is only warranted if a third subscriber
//  (export, logging, remote sync) actually appears — the indirection is not introduced
//  speculatively (KTD12).
//
import Foundation

/// A consumer of assembled samples (ring buffer, recording store). Receivers run on the
/// governor's collection queue — the single main-actor hop is the receiver's concern, not
/// the sink's.
protocol SampleReceiver: AnyObject {
    func receive(_ sample: Sample)
}

/// Fan-out point. Owned by the governor; confined to the collection queue (the governor is
/// its sole caller), which is why it need not be `Sendable`.
final class SampleSink {
    private var receivers: [SampleReceiver] = []

    init() {}

    /// Register a receiver. Receivers are held strongly for the app's lifetime; there is no
    /// dynamic unsubscribe in v1 (the ring buffer and store both live as long as the app).
    func register(_ receiver: SampleReceiver) {
        receivers.append(receiver)
    }

    /// Deliver one assembled sample to every receiver, in registration order.
    func emit(_ sample: Sample) {
        for receiver in receivers {
            receiver.receive(sample)
        }
    }
}
