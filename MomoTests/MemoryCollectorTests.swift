//
//  MemoryCollectorTests.swift
//  Fixture-driven coverage of memory assembly + pressure mapping (KTD11). `MemoryMath` is
//  pure, so byte/pressure math is tested without live `host_statistics64`; one smoke test
//  exercises the live read.
//
import XCTest
@testable import Momo

final class MemoryCollectorTests: XCTestCase {

    private func stats(
        total: UInt64 = 16 * 1_073_741_824,
        active: UInt64 = 0, inactive: UInt64 = 0, wired: UInt64 = 0, compressed: UInt64 = 0,
        pageSize: UInt64 = 16384, pressure: Int32 = 1, swap: UInt64 = 0
    ) -> MemoryStats {
        MemoryStats(totalBytes: total, active: active, inactive: inactive, wired: wired,
                    compressed: compressed, pageSize: pageSize, pressureLevel: pressure, swapUsedBytes: swap)
    }

    // Happy: used = (active+inactive+wired+compressed) × pageSize.
    func testUsedBytesIsSumOfNonFreePagesTimesPageSize() {
        let s = stats(active: 100, inactive: 50, wired: 25, compressed: 25, pageSize: 4096)
        let sample = MemoryMath.sample(from: s)
        XCTAssertEqual(sample.usedBytes, 200 * 4096)
        XCTAssertEqual(sample.swapUsedBytes, 0)
    }

    func testSwapAndTotalPassThrough() {
        let s = stats(total: 8_000_000_000, active: 10, pageSize: 4096, swap: 1_234_567)
        let sample = MemoryMath.sample(from: s)
        XCTAssertEqual(sample.totalBytes, 8_000_000_000)
        XCTAssertEqual(sample.swapUsedBytes, 1_234_567)
    }

    // Used is never reported above installed RAM even if page accounting overshoots.
    func testUsedClampedToTotal() {
        let s = stats(total: 1024, active: 1_000_000, pageSize: 4096)
        let sample = MemoryMath.sample(from: s)
        XCTAssertEqual(sample.usedBytes, 1024)
    }

    // Pressure level mapping: 1 normal / 2 warning / 4 critical; anything else → normal.
    func testPressureMapping() {
        XCTAssertEqual(MemoryMath.pressure(from: 1), .normal)
        XCTAssertEqual(MemoryMath.pressure(from: 2), .warning)
        XCTAssertEqual(MemoryMath.pressure(from: 4), .critical)
        XCTAssertEqual(MemoryMath.pressure(from: 0), .normal)   // unexpected → normal, not crash
        XCTAssertEqual(MemoryMath.pressure(from: 99), .normal)
    }

    func testPressureCarriedIntoSample() {
        XCTAssertEqual(MemoryMath.sample(from: stats(pressure: 2)).pressure, .warning)
        XCTAssertEqual(MemoryMath.sample(from: stats(pressure: 4)).pressure, .critical)
    }

    // reset() is a no-op for the stateless memory collector — must not throw or change reads.
    func testResetIsNoOp() throws {
        let collector = MemoryCollector()
        collector.reset()
        let sample = try collector.sample()
        XCTAssertGreaterThan(sample.totalBytes, 0)
    }

    // Live smoke: a real read is internally consistent.
    func testLiveReadIsConsistent() throws {
        let sample = try MemoryCollector().sample()
        XCTAssertGreaterThan(sample.totalBytes, 0)
        XCTAssertGreaterThan(sample.usedBytes, 0)
        XCTAssertLessThanOrEqual(sample.usedBytes, sample.totalBytes)
        XCTAssertEqual(sample.totalBytes, ProcessInfo.processInfo.physicalMemory)
    }
}
