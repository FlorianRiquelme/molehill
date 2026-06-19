//
//  CPUCollectorTests.swift
//  Fixture-driven coverage of CPU utilization delta math (KTD11). The pure `CPUMath`
//  functions are fed hand-computed tick snapshots so no live `host_processor_info` is needed;
//  one smoke test exercises the live read.
//
import XCTest
@testable import Momo

final class CPUCollectorTests: XCTestCase {

    // Happy path: known user/system/idle deltas → hand-calculated fractions.
    func testPerCoreUtilizationMatchesHandCalculation() {
        // Core 0: +50 user, +50 idle  -> 50% busy.
        // Core 1: +75 system, +25 idle -> 75% busy.
        // Core 2: +10 user +10 nice +80 idle -> 20% busy.
        let prior = [
            CPUTicks(user: 100, system: 0,  idle: 100, nice: 0),
            CPUTicks(user: 0,   system: 50, idle: 200, nice: 0),
            CPUTicks(user: 5,   system: 0,  idle: 20,  nice: 5),
        ]
        let current = [
            CPUTicks(user: 150, system: 0,   idle: 150, nice: 0),
            CPUTicks(user: 0,   system: 125, idle: 225, nice: 0),
            CPUTicks(user: 15,  system: 0,   idle: 100, nice: 15),
        ]
        let perCore = CPUMath.perCore(prior: prior, current: current)
        XCTAssertEqual(perCore[0], 0.50, accuracy: 1e-9)
        XCTAssertEqual(perCore[1], 0.75, accuracy: 1e-9)
        XCTAssertEqual(perCore[2], 0.20, accuracy: 1e-9)
    }

    // Overall is the aggregate busy/total ratio, NOT the mean of per-core fractions.
    func testOverallIsAggregateRatioNotMeanOfFractions() {
        // Core 0 advanced a lot (100 total, 100% busy); core 1 barely (10 total, 0% busy).
        // Mean of fractions = 50%. Aggregate = 100/110 ≈ 90.9%.
        let prior = [
            CPUTicks(user: 0, system: 0, idle: 0,  nice: 0),
            CPUTicks(user: 0, system: 0, idle: 0,  nice: 0),
        ]
        let current = [
            CPUTicks(user: 100, system: 0, idle: 0,  nice: 0),
            CPUTicks(user: 0,   system: 0, idle: 10, nice: 0),
        ]
        XCTAssertEqual(CPUMath.overall(prior: prior, current: current), 100.0 / 110.0, accuracy: 1e-9)
    }

    // Edge: a 32-bit counter that wraps must not produce a negative/absurd fraction.
    func testCounterWrapClampsToZero() {
        // user wraps from near-max back down; busy delta would be negative → clamp.
        let prior   = [CPUTicks(user: .max - 10, system: 0, idle: 1000, nice: 0)]
        let current = [CPUTicks(user: 5,         system: 0, idle: 2000, nice: 0)]
        let perCore = CPUMath.perCore(prior: prior, current: current)
        XCTAssertEqual(perCore[0], 0.0)
        XCTAssertGreaterThanOrEqual(perCore[0], 0.0)
        XCTAssertEqual(CPUMath.overall(prior: prior, current: current), 0.0)
    }

    // Edge: a core whose total did not advance (idle since last tick) is 0, never NaN.
    func testStalledCoreIsZeroNotNaN() {
        let same = CPUTicks(user: 10, system: 10, idle: 10, nice: 0)
        let perCore = CPUMath.perCore(prior: [same], current: [same])
        XCTAssertEqual(perCore[0], 0.0)
        XCTAssertFalse(perCore[0].isNaN)
    }

    // Fractions are clamped into 0...1 even if busy somehow exceeds total.
    func testUtilizationClampedToOne() {
        let prior   = [CPUTicks(user: 0,   system: 0, idle: 0, nice: 0)]
        // busy 100, total 100 -> exactly 1.0
        let current = [CPUTicks(user: 100, system: 0, idle: 0, nice: 0)]
        XCTAssertEqual(CPUMath.perCore(prior: prior, current: current)[0], 1.0, accuracy: 1e-9)
    }

    // Edge: first sample (no prior snapshot) returns zeroes sized to core count, not a spike.
    func testFirstSampleIsZeroNotSpike() throws {
        let collector = CPUCollector()
        let first = try collector.sample()
        XCTAssertEqual(first.overall, 0.0)
        XCTAssertTrue(first.perCore.allSatisfy { $0 == 0.0 })
        XCTAssertFalse(first.perCore.isEmpty)
    }

    // Edge: per-core array length equals the active logical core count.
    func testPerCoreLengthMatchesLogicalCores() throws {
        let collector = CPUCollector()
        let sample = try collector.sample()
        XCTAssertEqual(sample.perCore.count, ProcessInfo.processInfo.activeProcessorCount)
    }

    // reset() drops the prior snapshot so the next sample re-baselines (no spike post-resume).
    func testResetReBaselines() throws {
        let collector = CPUCollector()
        _ = try collector.sample()   // establishes prior
        collector.reset()
        let afterReset = try collector.sample()  // prior dropped → fresh
        XCTAssertEqual(afterReset.overall, 0.0)
        XCTAssertTrue(afterReset.perCore.allSatisfy { $0 == 0.0 })
    }

    // Live smoke: two real reads back-to-back yield in-range fractions.
    func testLiveReadProducesInRangeFractions() throws {
        let collector = CPUCollector()
        _ = try collector.sample()
        // Burn a little CPU so the second delta is non-trivial.
        var x = 0.0
        for i in 0..<2_000_000 { x += Double(i).squareRoot() }
        XCTAssertGreaterThanOrEqual(x, 0)
        let sample = try collector.sample()
        XCTAssertTrue((0.0...1.0).contains(sample.overall))
        XCTAssertTrue(sample.perCore.allSatisfy { (0.0...1.0).contains($0) })
    }
}
