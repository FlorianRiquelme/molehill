//
//  MetricSelectionTests.swift
//  U7 — menu-bar metric selection persistence (R2). The live-readout rendering + governor
//  suspend behavior are integration-verified by launching the app; this covers the cleanly
//  unit-testable part: the selection round-trips through UserDefaults across "relaunch".
//
import XCTest
@testable import Momo

@MainActor
final class MetricSelectionTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let suite = "momo.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        return d
    }

    func testDefaultsToCPUAndMemoryWhenUnset() {
        let sel = MetricSelection(defaults: freshDefaults())
        XCTAssertEqual(sel.selected, [.cpu, .memory])
    }

    func testToggleAddsAndRemovesPreservingCanonicalOrder() {
        let sel = MetricSelection(defaults: freshDefaults())
        sel.toggle(.memory)            // remove
        XCTAssertEqual(sel.selected, [.cpu])
        sel.toggle(.network)           // add (out of order)
        sel.toggle(.disk)              // add
        // Canonical order maintained regardless of toggle order.
        XCTAssertEqual(sel.selected, [.cpu, .disk, .network])
    }

    func testSelectionPersistsAcrossRelaunch() {
        let defaults = freshDefaults()
        do {
            let sel = MetricSelection(defaults: defaults)
            sel.toggle(.memory)        // deselect memory
            sel.toggle(.disk)          // select disk
            XCTAssertEqual(sel.selected, [.cpu, .disk])
        }
        // New instance reading the same defaults == "relaunch".
        let relaunched = MetricSelection(defaults: defaults)
        XCTAssertEqual(relaunched.selected, [.cpu, .disk])
    }

    func testEmptySelectionPersistsAsEmpty() {
        let defaults = freshDefaults()
        let sel = MetricSelection(defaults: defaults)
        sel.toggle(.cpu); sel.toggle(.memory)   // remove both defaults
        XCTAssertTrue(sel.selected.isEmpty)
        // Empty persisted selection stays empty on relaunch (not reset to the fallback).
        let relaunched = MetricSelection(defaults: defaults)
        XCTAssertTrue(relaunched.selected.isEmpty)
    }
}
