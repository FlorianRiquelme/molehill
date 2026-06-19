//
//  ScaffoldTests.swift
//  U1 has no behavioral tests (scaffolding/config unit). This placeholder keeps the test
//  target healthy and asserts the layer-neutral domain seam (KTD12) is assemblable, so the
//  collectors (U2+) have something to plug into. Real coverage starts in U2.
//
import XCTest
@testable import Momo

final class ScaffoldTests: XCTestCase {
    func testEmptySampleAssembles() {
        let sample = Sample(timestamp: Date(timeIntervalSince1970: 0))
        XCTAssertNil(sample.cpu)
        XCTAssertNil(sample.attribution)
        XCTAssertEqual(sample.context.power.displayAttached, true)
    }

    func testSampleSinkFansOutToReceivers() {
        final class Capture: SampleReceiver {
            var received: [Sample] = []
            func receive(_ sample: Sample) { received.append(sample) }
        }
        let sink = SampleSink()
        let a = Capture(), b = Capture()
        sink.register(a)
        sink.register(b)

        let sample = Sample(timestamp: Date(timeIntervalSince1970: 100))
        sink.emit(sample)

        XCTAssertEqual(a.received, [sample])
        XCTAssertEqual(b.received, [sample])
    }
}
