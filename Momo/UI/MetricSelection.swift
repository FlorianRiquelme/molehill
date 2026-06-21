//
//  MetricSelection.swift
//  User-selected subset of metrics shown in the menu-bar readout (R2), persisted to
//  UserDefaults so the choice survives relaunch.
//
//  v1 scope: the menu-bar readout offers the four always-on system metrics (CPU / memory /
//  disk / network). Sensors are a drill-down detail (U8), not a menu-bar metric — the governor
//  pauses sensor collection in menu-bar-only mode (KTD3), so surfacing a live sensor in the bar
//  would force detail collection while idle. Promoting a sensor to the bar (with its energy
//  cost) is a deliberate follow-up.
//
import Foundation

/// A metric that can appear in the menu-bar readout.
enum DisplayMetric: String, CaseIterable, Identifiable, Codable, Sendable {
    case cpu, memory, disk, network
    var id: String { rawValue }

    var label: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .disk: return "Disk"
        case .network: return "Network"
        }
    }

    /// Compact menu-bar prefix.
    var glyph: String {
        switch self {
        case .cpu: return "C"
        case .memory: return "M"
        case .disk: return "D"
        case .network: return "N"
        }
    }
}

/// Observable, UserDefaults-backed selection of which metrics show in the menu bar.
@MainActor
@Observable
final class MetricSelection {
    private static let defaultsKey = "momo.menubar.metrics"

    var selected: [DisplayMetric] {
        didSet { persist() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.array(forKey: Self.defaultsKey) as? [String] {
            // Key present is authoritative — an explicitly-emptied selection stays empty (menu
            // bar shows just "Momo"); only an ABSENT key falls back to the default subset.
            self.selected = raw.compactMap(DisplayMetric.init(rawValue:))
        } else {
            self.selected = Self.fallback
        }
    }

    func toggle(_ metric: DisplayMetric) {
        if let idx = selected.firstIndex(of: metric) {
            selected.remove(at: idx)
        } else {
            // Preserve canonical order so the menu bar layout is stable.
            selected = DisplayMetric.allCases.filter { selected.contains($0) || $0 == metric }
        }
    }

    func isSelected(_ metric: DisplayMetric) -> Bool { selected.contains(metric) }

    // MARK: -

    @ObservationIgnored private let defaults: UserDefaults
    private static let fallback: [DisplayMetric] = [.cpu, .memory]

    private func persist() {
        defaults.set(selected.map(\.rawValue), forKey: Self.defaultsKey)
    }
}
