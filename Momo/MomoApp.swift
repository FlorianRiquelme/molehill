//
//  MomoApp.swift
//  @main entry point — accessory menu-bar app (KTD8).
//
//  MenuBarExtra `.window` style hosts arbitrary SwiftUI for the live readout (U7) and
//  drill-down panels (U8). U1 ships an empty placeholder panel; later units replace the
//  content and the governor/store are wired behind it.
//
import SwiftUI

@main
struct MomoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Momo", systemImage: "gauge") {
            MenuBarContentView()
        }
        .menuBarExtraStyle(.window)
    }
}

/// Placeholder menu-bar panel for U1. Replaced by the live readout (U7) and the
/// metric drill-down (U8).
private struct MenuBarContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Momo")
                .font(.headline)
            Text("System monitor — scaffold")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 220, alignment: .leading)
    }
}
