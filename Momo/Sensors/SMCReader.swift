//
//  SMCReader.swift
//  Intel sensor path — AppleSMC IOKit user-client (KTD5, R1 temps/fans).
//
//  Fixture-tested only: this dev machine is Apple Silicon, so the live IOKit path here is
//  unexercised (OQ9 — Intel support is best-effort for v1). What IS covered by tests are
//  the parts that can be wrong without hardware:
//   * the byte decoders (SP78 / FPE2 / FLT) — pure functions, fixture-tested directly;
//   * the `SMCKeyData_t` struct stride assert — refuses to open the SMC on layout drift
//     (a toolchain/OS change to the struct would otherwise read corrupt bytes, KTD5).
//
//  Flow per key: `readKeyInfo` (size + data type) then `readBytes`, then decode by type.
//  Fans come from `FNum` (count) → per-fan `F<i>Ac` actual RPM; a fanless Mac (FNum == 0)
//  yields an empty fan list, never a zero-RPM fan.
//
//  Confined to the governor queue and NOT `Sendable` (KTD11): it owns the mach connection.
//
import Foundation
import IOKit

// MARK: - Pure decoders (fixture-tested, no hardware)

/// SMC byte-encoding decoders. All pure — given the raw bytes + data-type FourCC, return
/// the engineering value. These are the load-bearing correctness surface for the SMC path.
enum SMCDecode {
    /// `sp78` — signed fixed-point, 1 sign + 7 integer + 8 fraction bits, big-endian.
    /// Used by virtually all SMC temperature keys. e.g. bytes 0x2D 0x00 -> 45.0 °C.
    static func sp78(_ bytes: [UInt8]) -> Double? {
        guard bytes.count >= 2 else { return nil }
        let raw = Int16(bitPattern: (UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
        return Double(raw) / 256.0
    }

    /// `fpe2` — unsigned fixed-point, 14 integer + 2 fraction bits, big-endian. Used by
    /// fan RPM keys on older SMC revisions. e.g. bytes 0x0A 0xF0 -> 700.0 rpm.
    static func fpe2(_ bytes: [UInt8]) -> Double? {
        guard bytes.count >= 2 else { return nil }
        let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        return Double(raw) / 4.0
    }

    /// `flt ` — little-endian IEEE-754 32-bit float. Used by fan RPM and some temps on
    /// newer Intel SMC revisions.
    static func flt(_ bytes: [UInt8]) -> Double? {
        guard bytes.count >= 4 else { return nil }
        let bits = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8)
                 | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
        return Double(Float(bitPattern: bits))
    }

    /// `ui8`/`ui16`/`ui32` — big-endian unsigned integers (e.g. `FNum` fan count is `ui8`).
    static func uint(_ bytes: [UInt8]) -> Double? {
        guard !bytes.isEmpty else { return nil }
        var value: UInt64 = 0
        for b in bytes.prefix(8) { value = (value << 8) | UInt64(b) }
        return Double(value)
    }

    /// Decode by SMC data-type FourCC (e.g. "sp78", "fpe2", "flt ", "ui8 ").
    static func value(type: String, bytes: [UInt8]) -> Double? {
        switch type {
        case "sp78": return sp78(bytes)
        case "fpe2": return fpe2(bytes)
        case "flt ": return flt(bytes)
        case let t where t.hasPrefix("ui"): return uint(bytes)
        default: return nil
        }
    }
}

// MARK: - AppleSMC wire structs (stride-pinned — KTD5)

/// Mirrors the kernel `SMCKeyData_t` ABI used by `IOConnectCallStructMethod`. The layout
/// is undocumented-but-stable; `SMCReader.layoutIsStable()` refuses to open the SMC if the
/// compiled stride ever drifts from the known-good baseline, so a toolchain/OS change is
/// caught at startup rather than silently feeding corrupt bytes into history.
///
/// CAVEAT (fixture-only, OQ9): the Swift compiler packs this to 76 bytes; the widely-cited
/// C `SMCKeyData_t` is 80. This struct is never exercised against real Intel hardware in
/// v1, so the live byte layout is UNVERIFIED — before trusting live Intel reads, confirm
/// the struct round-trips against an actual AppleSMC user-client (it may need explicit
/// padding to the 80-byte C ABI). The stride assert here guards drift from *this* pinned
/// value; it is not a claim of C-ABI correctness.
struct SMCKeyDataVers {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCKeyDataPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

struct SMCKeyDataKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

/// 32-byte SMC value buffer (the kernel `SMCBytes_t`).
typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

struct SMCKeyData {
    var key: UInt32 = 0
    var vers = SMCKeyDataVers()
    var pLimitData = SMCKeyDataPLimitData()
    var keyInfo = SMCKeyDataKeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )
}

// MARK: - Backend protocol (injectable for tests)

/// One decoded SMC key read: the data-type FourCC and the raw value bytes. Decoding is
/// done by `SMCDecode` so the backend stays a thin transport.
struct SMCKeyReading: Equatable {
    let type: String
    let bytes: [UInt8]
}

/// The thin transport surface SensorProbe drives. The live implementation is
/// `SMCReader`; tests inject a fake so the probe/intersection logic needs no hardware.
protocol SMCBackend: AnyObject {
    /// Read a key's type + raw bytes, or nil if the key is absent / errors.
    func read(key: String) -> SMCKeyReading?
}

// MARK: - Live reader

/// Live AppleSMC user-client. Confined to the governor queue; not `Sendable` (KTD11).
final class SMCReader: SMCBackend {
    /// Known-good `SMCKeyData` stride as the current Swift toolchain lays it out. If the
    /// compiled struct ever differs, we refuse to open the connection (KTD5 stride-drift
    /// guard). NOTE: this is the *Swift* stride, which packs tighter than the C ABI's 80
    /// bytes — what matters is detecting drift from this pinned value, not matching C.
    static let expectedKeyDataStride = 76

    /// True when the compiled struct matches the pinned ABI. SensorProbe checks this
    /// before constructing/opening a live `SMCReader`.
    static func layoutIsStable() -> Bool {
        MemoryLayout<SMCKeyData>.stride == expectedKeyDataStride
    }

    private var connection: io_connect_t = 0
    private var isOpen = false

    /// Opens the AppleSMC user-client. Returns nil (does not crash) on stride drift or if
    /// the service is unavailable — the probe then reports zero SMC sensors rather than
    /// reading corrupt bytes.
    init?() {
        guard SMCReader.layoutIsStable() else {
            assertionFailure("SMCKeyData stride drift: \(MemoryLayout<SMCKeyData>.stride) != \(SMCReader.expectedKeyDataStride) — refusing to open AppleSMC (KTD5)")
            return nil
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == kIOReturnSuccess else { return nil }
        isOpen = true
    }

    deinit {
        if isOpen { IOServiceClose(connection) }
    }

    func read(key: String) -> SMCKeyReading? {
        guard isOpen, let fourCC = SMCReader.fourCC(key) else { return nil }

        // 1. readKeyInfo: data size + type FourCC.
        var infoIn = SMCKeyData()
        infoIn.key = fourCC
        infoIn.data8 = 9 // kSMCGetKeyInfo
        guard let info = call(&infoIn) else { return nil }
        let size = Int(info.keyInfo.dataSize)
        guard size > 0, size <= 32 else { return nil }
        let type = SMCReader.fourCCString(info.keyInfo.dataType)

        // 2. readBytes.
        var readIn = SMCKeyData()
        readIn.key = fourCC
        readIn.keyInfo.dataSize = UInt32(size)
        readIn.data8 = 5 // kSMCReadKey
        guard let out = call(&readIn) else { return nil }

        var raw = [UInt8](repeating: 0, count: size)
        withUnsafeBytes(of: out.bytes) { buf in
            for i in 0..<size { raw[i] = buf[i] }
        }
        return SMCKeyReading(type: type, bytes: raw)
    }

    private func call(_ input: inout SMCKeyData) -> SMCKeyData? {
        var output = SMCKeyData()
        var outSize = MemoryLayout<SMCKeyData>.stride
        let result = IOConnectCallStructMethod(
            connection, 2, // kSMCHandleYPCEvent
            &input, MemoryLayout<SMCKeyData>.stride,
            &output, &outSize
        )
        guard result == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    /// "TC0P" -> 0x54433050 (big-endian FourCC).
    static func fourCC(_ key: String) -> UInt32? {
        let scalars = Array(key.utf8)
        guard scalars.count == 4 else { return nil }
        return scalars.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    static func fourCCString(_ value: UInt32) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }
}
