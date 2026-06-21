---
title: IOHIDEventSystemClient bridging-header collision on macOS 26
date: 2026-06-21
category: docs/solutions/build-errors
module: Sensors
problem_type: build_error
component: tooling
symptoms:
  - "Swift compile error: \"'IOHIDEventSystemClientRef' has been renamed\" once a file actually uses the private HID symbols"
  - "Re-typedef'd opaque *Ref types make Swift mis-manage CF create/copy memory (lifetime bugs)"
  - "`CFRelease` is unavailable from Swift (\"Core Foundation objects are automatically memory managed\")"
root_cause: wrong_api
resolution_type: code_fix
severity: medium
tags: [macos-26, iohideventsystemclient, bridging-header, apple-silicon, private-api, sensors]
---

# IOHIDEventSystemClient bridging-header collision on macOS 26

## Problem

Reading Apple Silicon temperature/fan sensors in-process (no privileged helper) requires the
private `IOHIDEventSystemClient` API. The long-standing pattern (e.g. exelban/stats) is to
hand-declare the opaque `*Ref` typedefs and the functions in a bridging header. On **macOS 26**
that pattern no longer compiles: the SDK now ships *public* `hidsystem/IOHIDEventSystemClient.h`
and `hidsystem/IOHIDServiceClient.h` that declare the `*Ref` types as **CF-bridged objects** plus
a *subset* of the functions — so the hand-authored typedefs collide with the SDK's.

## Symptoms

- `'IOHIDEventSystemClientRef' has been renamed` at the first site that pulls the SDK `hidsystem`
  headers into the same translation unit as the hand-authored typedefs.
- The scaffold compiled fine *earlier* (when nothing imported the SDK HID header), then broke
  only once the real sensor reader exercised the symbols — a deferred collision.
- Naively re-`typedef`'ing the `*Ref` types to silence the rename makes Swift mis-bridge the
  CF create/copy memory rules (lifetime/ownership bugs).

## What Didn't Work

- **Hand-declaring everything** (the pre-macOS-26 / exelban/stats approach: all `*Ref` typedefs +
  all functions). Compiles in isolation but collides with the SDK's now-public partial
  declarations the moment SDK `hidsystem` headers are in scope.
- **Re-typedef'ing the `*Ref` types as plain `struct ... *`** to win the name fight. This defeats
  the SDK's CF bridging, so ARC stops managing the client/service objects correctly.
- **`CFRelease(...)` to balance a `Copy`-rule event** — unavailable from Swift (CF is
  auto-managed); the compiler rejects it.

## Solution

Let the SDK own every type it now declares; hand-declare **only** the symbols the SDK still omits.

```c
// Momo-Bridging-Header.h — include the SDK headers so the *Ref TYPES come from the SDK
// (single source of truth; correct CF bridging), then declare only the still-private functions.
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>  // IOHIDEventSystemClientRef (CF-bridged), CopyServices, CopyProperty
#include <IOKit/hidsystem/IOHIDServiceClient.h>       // IOHIDServiceClientRef (CF-bridged)

typedef struct __IOHIDEvent *IOHIDEventRef;            // still NOT in any SDK header

#ifdef __cplusplus
extern "C" {
#endif
// Still private (not in any SDK header):
IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
int  IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service,
                                          int64_t type, int32_t options, int64_t timestamp);
double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);
#ifdef __cplusplus
}
#endif

// Swift does NOT import function-like C macros, so expose IOHIDEventFieldBase(type) = type << 16
// as a static inline function the Swift side can call directly.
static inline int32_t MomoIOHIDEventFieldBase(int32_t type) { return type << 16; }
```

`IOHIDServiceClientCopyEvent` follows the CF **Copy** rule (caller owns the result), but its
return type `IOHIDEventRef` is a **raw `OpaquePointer`** (not CF-bridged), so ARC will *not*
release it — and `CFRelease` is unavailable from Swift. Release it manually each call or it leaks
one event per sensor per read:

```swift
guard let event = IOHIDServiceClientCopyEvent(service, Int64(kIOHIDEventTypeTemperature), 0, 0)
else { continue }
defer { Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(event)).release() }
let celsius = IOHIDEventGetFloatValue(event, MomoIOHIDEventFieldBase(Int32(kIOHIDEventTypeTemperature)))
```

## Why This Works

macOS 26 promoted part of the `IOHIDEventSystemClient` surface into public SDK headers, declaring
the client/service `*Ref` types as CF objects. Once the SDK declares a type, re-declaring it in a
bridging header is a redefinition conflict, and overriding it with a plain pointer fights the CF
bridging Swift relies on for ownership. Including the SDK headers makes the SDK the single source
of truth for those types (correct ARC lifetimes for `Create`/`Copy` on the client and service),
while the bridging header is reduced to its true job: the handful of functions the SDK still
doesn't expose. `IOHIDEventRef` stays a raw pointer because it's still fully private — hence the
explicit `Unmanaged.release()`.

## Prevention

- **Bridge by gap, not by blanket.** Include the SDK header for any type the SDK already declares;
  hand-declare only the genuinely-missing symbols. Don't re-`typedef` SDK-owned types.
- **Re-audit private symbols on every OS/SDK bump.** A symbol that needed hand-declaring on the
  previous OS may be public now — SDK churn turns yesterday's bridging header into a collision.
- **A bridging-header "compiles" gate is not enough.** The collision only fires when a TU pulls in
  both the SDK header and the redeclaration. Exercise the symbols for real (a smoke reference, or
  the actual reader) before trusting the header.
- **Raw (non-CF-bridged) `Copy`/`Create` results need manual release** via
  `Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(ptr)).release()` — `CFRelease` is unavailable
  from Swift. A per-tick leak in a continuously-running monitor is the failure mode.
- **Function-like C macros don't import to Swift** — wrap them as `static inline` C functions in
  the bridging header.

## Related Issues

- Plan: `docs/plans/2026-06-19-001-feat-macos-system-monitor-plan.md` (KTD5 — data-driven sensor
  support; U1 bridging-header gate; U3 SMC/HID subsystem).
- Known residuals: `docs/residual-review-findings/feat-momo-system-monitor.md` (the HID event-leak
  fix originated from the same surface).
- Prototype source for the HID reader shape: exelban/stats (pre-macOS-26 hand-declared pattern).
