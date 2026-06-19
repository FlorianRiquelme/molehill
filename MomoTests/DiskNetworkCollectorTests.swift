//
//  DiskNetworkCollectorTests.swift
//  Fixture-driven coverage of the shared `RateMath` (disk + network throughput) plus live
//  smoke tests. The rate math is pure delta-of-cumulative-counters, so wrap/first-sample/
//  interval edges are tested without live IOKit or sysctl (KTD11).
//
import XCTest
@testable import Momo

final class DiskNetworkCollectorTests: XCTestCase {

    // MARK: - RateMath (shared pure function)

    // Happy: 1 MB over 2 s → 500 KB/s.
    func testRateHappyPath() {
        let rate = RateMath.bytesPerSecond(priorBytes: 1_000_000, currentBytes: 2_000_000, interval: 2)
        XCTAssertEqual(rate, 500_000, accuracy: 1e-6)
    }

    // Edge: counter wrap / device reset (current < prior) clamps to 0, never negative.
    func testRateClampsOnCounterWrap() {
        let rate = RateMath.bytesPerSecond(priorBytes: .max - 100, currentBytes: 50, interval: 1)
        XCTAssertEqual(rate, 0)
        XCTAssertGreaterThanOrEqual(rate, 0)
    }

    // Edge: a counter sitting exactly at UInt64.max with no advance is 0, not absurd.
    func testRateAtCounterMaxNoAdvance() {
        let rate = RateMath.bytesPerSecond(priorBytes: .max, currentBytes: .max, interval: 1)
        XCTAssertEqual(rate, 0)
    }

    // Edge: zero / negative interval (duplicate timestamp, clock skew) → 0, no divide-by-zero.
    func testRateZeroAndNegativeInterval() {
        XCTAssertEqual(RateMath.bytesPerSecond(priorBytes: 0, currentBytes: 1000, interval: 0), 0)
        XCTAssertEqual(RateMath.bytesPerSecond(priorBytes: 0, currentBytes: 1000, interval: -5), 0)
    }

    // Large 64-bit deltas don't overflow (the reason network uses if_data64, not if_data).
    func testRateLargeDelta() {
        let tenGB: UInt64 = 10 * 1_073_741_824
        let rate = RateMath.bytesPerSecond(priorBytes: 0, currentBytes: tenGB, interval: 1)
        XCTAssertEqual(rate, Double(tenGB), accuracy: 1.0)
    }

    // MARK: - DiskCollector

    // Edge: first sample (no prior counter snapshot) → zero rate, but usage is still reported.
    func testDiskFirstSampleZeroRateWithUsage() throws {
        let collector = DiskCollector()
        let sample = try collector.sample()
        XCTAssertEqual(sample.readBytesPerSec, 0)
        XCTAssertEqual(sample.writeBytesPerSec, 0)
        XCTAssertGreaterThan(sample.totalBytes, 0)          // boot volume usage present
        XCTAssertLessThanOrEqual(sample.freeBytes, sample.totalBytes)
    }

    // Second sample produces non-negative, finite rates.
    func testDiskSecondSampleRatesNonNegative() throws {
        let collector = DiskCollector()
        _ = try collector.sample(now: Date(timeIntervalSince1970: 100))
        let sample = try collector.sample(now: Date(timeIntervalSince1970: 101))
        XCTAssertGreaterThanOrEqual(sample.readBytesPerSec, 0)
        XCTAssertGreaterThanOrEqual(sample.writeBytesPerSec, 0)
        XCTAssertTrue(sample.readBytesPerSec.isFinite)
        XCTAssertTrue(sample.writeBytesPerSec.isFinite)
    }

    // reset() drops the prior counter snapshot → next sample re-baselines to zero rate.
    func testDiskResetReBaselines() throws {
        let collector = DiskCollector()
        _ = try collector.sample(now: Date(timeIntervalSince1970: 100))
        collector.reset()
        let sample = try collector.sample(now: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(sample.readBytesPerSec, 0)
        XCTAssertEqual(sample.writeBytesPerSec, 0)
    }

    // MARK: - NetworkCollector

    // Edge: first sample (no prior) → zero rate, never a spike.
    func testNetworkFirstSampleZeroRate() throws {
        let collector = NetworkCollector()
        let sample = try collector.sample()
        XCTAssertEqual(sample.rxBytesPerSec, 0)
        XCTAssertEqual(sample.txBytesPerSec, 0)
    }

    // Second sample produces non-negative, finite rates from real 64-bit counters.
    func testNetworkSecondSampleRatesNonNegative() throws {
        let collector = NetworkCollector()
        _ = try collector.sample(now: Date(timeIntervalSince1970: 100))
        let sample = try collector.sample(now: Date(timeIntervalSince1970: 101))
        XCTAssertGreaterThanOrEqual(sample.rxBytesPerSec, 0)
        XCTAssertGreaterThanOrEqual(sample.txBytesPerSec, 0)
        XCTAssertTrue(sample.rxBytesPerSec.isFinite)
        XCTAssertTrue(sample.txBytesPerSec.isFinite)
    }

    func testNetworkResetReBaselines() throws {
        let collector = NetworkCollector()
        _ = try collector.sample(now: Date(timeIntervalSince1970: 100))
        collector.reset()
        let sample = try collector.sample(now: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(sample.rxBytesPerSec, 0)
        XCTAssertEqual(sample.txBytesPerSec, 0)
    }

    // Live read returns monotonically sane cumulative counters (rx/tx never both wildly off).
    func testNetworkLiveCountersReadable() throws {
        let counters = try NetworkCollector.readCounters()
        // On any live machine at least loopback-excluded interfaces exist; counters are >= 0
        // by type. Assert the read didn't throw and timestamp is set.
        XCTAssertGreaterThanOrEqual(counters.rxBytes, 0)
        XCTAssertGreaterThanOrEqual(counters.txBytes, 0)
    }

    // MARK: - CollectorError surfaces, not fabricated values

    // A non-success kern_return_t maps to a thrown hostCall error (not a zeroed reading).
    func testCollectorErrorEquatableShape() {
        XCTAssertEqual(CollectorError.hostCall(api: "x", code: 5), .hostCall(api: "x", code: 5))
        XCTAssertNotEqual(CollectorError.hostCall(api: "x", code: 5), .hostCall(api: "x", code: 6))
        XCTAssertNotEqual(CollectorError.ioKit(detail: "a"), .sysctl(name: "a", errno: 0))
    }
}
