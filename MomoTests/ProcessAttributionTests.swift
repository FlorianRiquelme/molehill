//
//  ProcessAttributionTests.swift
//  U4 — per-process attribution (R6; KTD4a, KTD4b, KTD10).
//
import XCTest
@testable import Momo

final class ProcessAttributionTests: XCTestCase {

    // MARK: ProcMath (pure delta math, incl. Apple Silicon timebase — KTD10)

    func testMachToNanosAppliesTimebase() {
        // Apple Silicon timebase on this machine is 125/3: 3 ticks -> 125 ns.
        XCTAssertEqual(ProcMath.machToNanos(3, numer: 125, denom: 3), 125)
        // Intel identity timebase 1/1 is a no-op.
        XCTAssertEqual(ProcMath.machToNanos(1_000, numer: 1, denom: 1), 1_000)
        // Large value uses the split path without overflow.
        XCTAssertEqual(ProcMath.machToNanos(3_000_000, numer: 125, denom: 3), 125_000_000)
    }

    func testCpuFractionHandCalc() {
        // 0.5s of CPU time over a 1s wall interval => 0.5 of one core.
        let frac = ProcMath.cpuFraction(priorNs: 0, currentNs: 500_000_000, wallSeconds: 1.0)
        XCTAssertEqual(frac, 0.5, accuracy: 1e-9)
        // A fully-busy multithreaded process can exceed 1.0 (matches Activity Monitor).
        let multi = ProcMath.cpuFraction(priorNs: 0, currentNs: 2_000_000_000, wallSeconds: 1.0)
        XCTAssertEqual(multi, 2.0, accuracy: 1e-9)
    }

    func testCpuFractionClampsWrapAndBadInterval() {
        XCTAssertEqual(ProcMath.cpuFraction(priorNs: 100, currentNs: 50, wallSeconds: 1.0), 0)   // counter went backwards
        XCTAssertEqual(ProcMath.cpuFraction(priorNs: 0, currentNs: 100, wallSeconds: 0), 0)      // zero interval
        XCTAssertEqual(ProcMath.cpuFraction(priorNs: 0, currentNs: 100, wallSeconds: -1), 0)     // negative interval
    }

    func testDiskRateHandCalc() {
        // 1 MiB read+write delta over 2s => 512 KiB/s.
        let rate = ProcMath.diskRate(priorBytes: 0, currentBytes: 1_048_576, wallSeconds: 2.0)
        XCTAssertEqual(rate, 524_288, accuracy: 1e-6)
        XCTAssertEqual(ProcMath.diskRate(priorBytes: 10, currentBytes: 5, wallSeconds: 1.0), 0) // wrap clamps
    }

    // MARK: BoundedTopN

    func testBoundedTopNKeepsHighestNRanked() {
        var top = BoundedTopN<Int>(capacity: 3)
        for (i, v) in [10.0, 50.0, 30.0, 5.0, 90.0, 20.0].enumerated() {
            top.insert(value: v, i)        // element is the input index
        }
        let survivors = top.sortedDescending()
        XCTAssertEqual(survivors.count, 3)                      // exactly N
        XCTAssertEqual(survivors.map { $0.value }, [90, 50, 30]) // top 3, ranked
    }

    func testBoundedTopNFewerThanCapacity() {
        var top = BoundedTopN<String>(capacity: 5)
        top.insert(value: 1, "a")
        top.insert(value: 2, "b")
        let survivors = top.sortedDescending()
        XCTAssertEqual(survivors.count, 2)
        XCTAssertEqual(survivors.map { $0.element }, ["b", "a"])
    }

    // MARK: Live libproc smoke (deterministic invariants, not exact values)

    func testLiveSampleProducesRankedTopNPerSubsystem() throws {
        let collector = try ProcessAttributionCollector(foregroundProvider: { "TestApp" })
        let t0 = Date()
        _ = try collector.sample(at: t0)                       // first sample: establishes prior
        let s = try collector.sample(at: t0.addingTimeInterval(0.2))

        for subsystem in Subsystem.allCases {
            let rows = s.bySubsystem[subsystem] ?? []
            XCTAssertLessThanOrEqual(rows.count, ProcessAttributionCollector.topN)
            // ranked descending by value
            XCTAssertEqual(rows, rows.sorted { $0.value > $1.value })
            // leaf names only — never a path separator (KTD4b)
            for r in rows { XCTAssertFalse(r.name.contains("/"), "name must be leaf-only: \(r.name)") }
        }
        // This process (the test host) should show some memory footprint.
        let mem = s.bySubsystem[.memory] ?? []
        XCTAssertFalse(mem.isEmpty)
        XCTAssertGreaterThan(mem.first!.value, 0)
    }

    func testFirstSampleHasNoRatesNoSpike() throws {
        let collector = try ProcessAttributionCollector(foregroundProvider: { nil })
        let first = try collector.sample(at: Date())
        // No prior => CPU and disk rate rows are empty (no fabricated startup spike).
        XCTAssertTrue((first.bySubsystem[.cpu] ?? []).isEmpty)
        XCTAssertTrue((first.bySubsystem[.disk] ?? []).isEmpty)
        // Memory is instantaneous, so it is populated on the first sample.
        XCTAssertFalse((first.bySubsystem[.memory] ?? []).isEmpty)
    }

    func testResetClearsPriorSoNextSampleIsFresh() throws {
        let collector = try ProcessAttributionCollector(foregroundProvider: { nil })
        let t = Date()
        _ = try collector.sample(at: t)
        _ = try collector.sample(at: t.addingTimeInterval(0.2)) // now has CPU rates
        collector.reset()
        let afterReset = try collector.sample(at: t.addingTimeInterval(0.4))
        XCTAssertTrue((afterReset.bySubsystem[.cpu] ?? []).isEmpty) // fresh again, no spike
    }

    // MARK: Correlated state (R6)

    func testCorrelatedStateReflectsInjectedForegroundAndPower() throws {
        let collector = try ProcessAttributionCollector(foregroundProvider: { "Xcode" })
        let power = PowerSnapshot(onBattery: true, lowPowerMode: true, displayAttached: false, asleep: false)
        let state = collector.correlatedState(power: power)
        XCTAssertEqual(state.foregroundApp, "Xcode")
        XCTAssertEqual(state.power, power)
    }
}
