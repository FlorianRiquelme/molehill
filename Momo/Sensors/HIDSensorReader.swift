//
//  HIDSensorReader.swift
//  Apple Silicon sensor path — IOHIDEventSystemClient (KTD5, R1 temps/fans).
//
//  Live-verifiable on this machine (arm64). macOS 26 removed
//  `powermetrics --samplers smc`, so this private HID path is mandatory on Apple Silicon.
//
//  Flow: IOHIDEventSystemClientCreate → matching dict (PrimaryUsagePage 0xff00,
//  PrimaryUsage 0x0005) → IOHIDEventSystemClientCopyServices → per service
//  IOHIDServiceClientCopyEvent(kIOHIDEventTypeTemperature) →
//  IOHIDEventGetFloatValue(event, IOHIDEventFieldBase(kIOHIDEventTypeTemperature)).
//  Service friendly name via IOHIDServiceClientCopyProperty(service, "Product").
//
//  The temperature value is already in degrees Celsius (no decode), so `temperatureDegrees`
//  is an identity passthrough — kept as a named pure function so the HID happy-path test
//  has a stable seam to assert against.
//
//  Confined to the governor queue and NOT `Sendable` (KTD11): owns the HID client.
//
import Foundation
import IOKit

/// One HID temperature service: its friendly `Product` name and the current reading.
struct HIDSensorReading: Equatable {
    let product: String
    let celsius: Double
}

/// The thin transport surface SensorProbe drives. Live implementation is
/// `HIDSensorReader`; tests inject a fake so probe/intersection logic needs no hardware.
protocol HIDBackend: AnyObject {
    /// All temperature services discovered on this machine, with current readings.
    func temperatureReadings() -> [HIDSensorReading]
}

/// Maps a raw HID temperature event float to degrees Celsius. Identity for the
/// temperature usage page (the event value is already °C); named so it is unit-testable
/// and so a future scale/offset correction has one place to live.
func hidTemperatureDegrees(_ rawFloatValue: Double) -> Double {
    rawFloatValue
}

/// Live IOHIDEventSystemClient reader. Confined to the governor queue; not `Sendable`.
///
/// macOS 26: the opaque `*Ref` types come from the SDK's public hidsystem headers as
/// CF-bridged objects, so `IOHIDEventSystemClientCreate` (bridging header) follows the CF
/// *create* rule and returns `Unmanaged` — we take ownership once at init. The field-base
/// computation is a function-like C macro that Swift can't import, so it's exposed as the
/// inline `MomoIOHIDEventFieldBase` shim from the bridging header.
final class HIDSensorReader: HIDBackend {
    private let client: IOHIDEventSystemClient

    // AppleVendor HID sensor service identifiers (KTD5).
    private static let primaryUsagePage = 0xff00
    private static let primaryUsage = 0x0005

    init?() {
        guard let unmanaged = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else { return nil }
        self.client = unmanaged.takeRetainedValue()

        let match: [String: Int] = [
            "PrimaryUsagePage": Self.primaryUsagePage,
            "PrimaryUsage": Self.primaryUsage,
        ]
        _ = IOHIDEventSystemClientSetMatching(client, match as CFDictionary)
    }

    func temperatureReadings() -> [HIDSensorReading] {
        guard let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient]
        else { return [] }

        var readings: [HIDSensorReading] = []
        let field = MomoIOHIDEventFieldBase(Int32(kIOHIDEventTypeTemperature))

        for service in services {
            // IOHIDServiceClientCopyEvent returns a plain IOHIDEventRef (OpaquePointer);
            // IOHIDEvent is not CF-bridged so there is no Unmanaged wrapper here.
            guard let event = IOHIDServiceClientCopyEvent(
                service, Int64(kIOHIDEventTypeTemperature), 0, 0
            ) else { continue }
            // IOHIDServiceClientCopyEvent follows the CF Copy rule (caller owns), but the
            // returned IOHIDEventRef is a raw OpaquePointer (not CF-bridged), so ARC won't
            // release it. Balance the +1 retain explicitly or we leak one per service per tick.
            defer { Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(event)).release() }

            let raw = IOHIDEventGetFloatValue(event, field)
            let product = (IOHIDServiceClientCopyProperty(service, "Product" as CFString) as? String) ?? "Unknown"
            readings.append(HIDSensorReading(product: product, celsius: hidTemperatureDegrees(raw)))
        }
        return readings
    }
}
