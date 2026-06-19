//
//  AppDelegate.swift
//  Accessory lifecycle + system sleep/wake wiring.
//
//  The four NSWorkspace sleep/wake notifications are observed here and surfaced as
//  callbacks the polling governor (U5) wires into. In U1 they default to no-ops so the
//  scaffold is self-contained; the governor assigns real handlers (suspend collection on
//  sleep, run the store catch-up pass on wake).
//
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Sleep/wake hooks the governor (U5) consumes. Default no-ops.
    var onWillSleep: (() -> Void)?
    var onDidWake: (() -> Void)?
    var onScreensDidSleep: (() -> Void)?
    var onScreensDidWake: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt-and-suspenders with LSUIElement: guarantee accessory mode (no Dock icon).
        NSApp.setActivationPolicy(.accessory)
        observeSystemSleep()
    }

    /// Observe the four sleep/wake notifications (pattern: MacSlowCooker
    /// `AppDelegate.observeSystemSleep`). Workspace notifications deliver on the main thread.
    private func observeSystemSleep() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(willSleep),
                       name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(didWake),
                       name: NSWorkspace.didWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(screensDidSleep),
                       name: NSWorkspace.screensDidSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(screensDidWake),
                       name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    @objc private func willSleep() { onWillSleep?() }
    @objc private func didWake() { onDidWake?() }
    @objc private func screensDidSleep() { onScreensDidSleep?() }
    @objc private func screensDidWake() { onScreensDidWake?() }

    /// macOS 26 accessory-app regression (KTD8): programmatic window activation is broken
    /// for menu-bar apps, so any window we present must be activated + ordered front
    /// manually rather than relying on `openSettings`/automatic activation.
    func activateAndOrderFront(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
