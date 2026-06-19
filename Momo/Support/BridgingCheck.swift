//
//  BridgingCheck.swift
//  U1 compile/link gate for the bridging header.
//
//  Proves the bridging header's public (libproc) and private (IOHIDEventSystemClient) C
//  symbols are visible to Swift and resolve against IOKit at link time. Never called at
//  runtime — its existence is the verification. Superseded once U2 (libproc/host_*) and
//  U3 (IOHIDEventSystemClient) exercise these APIs for real; remove then.
//
import Foundation

enum BridgingCheck {
    static func symbolsResolve() {
        // Public: libproc enumeration (U4 will use this for real).
        var pids = [pid_t](repeating: 0, count: 8)
        _ = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids,
                          Int32(pids.count * MemoryLayout<pid_t>.size))

        // Private: Apple Silicon HID sensor client (U3 will use this for real).
        _ = IOHIDEventSystemClientCreate(kCFAllocatorDefault)
    }
}
