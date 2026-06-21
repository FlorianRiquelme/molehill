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

    private var services: MomoServices { MomoServices.shared }

    var body: some Scene {
        MenuBarExtra {
            MomoPanel(live: services.live,
                      selection: services.selection,
                      sensorCapability: services.sensorCapability)
        } label: {
            MenuBarLabel(live: services.live, selection: services.selection)
        }
        .menuBarExtraStyle(.window)
    }
}
