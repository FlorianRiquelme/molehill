//
//  Momo-Bridging-Header.h
//  Exposes the C APIs Momo's collectors need to Swift.
//
//  Two groups:
//   1. Public system APIs (libproc, sysctl, mach, IOKit) — declared in the SDK.
//   2. Private IOHIDEventSystemClient APIs (Apple Silicon temps/fans) — NOT in any
//      public SDK header. The only shipped IOHIDEventSystemClient.h is the driver-side
//      header and does not declare these user-space symbols, so they are hand-authored
//      here (prototype source: exelban/stats HID reader). Link target: IOKit.
//
#ifndef Momo_Bridging_Header_h
#define Momo_Bridging_Header_h

#include <CoreFoundation/CoreFoundation.h>

// --- Group 1: public system APIs ---------------------------------------------
#include <libproc.h>            // proc_listpids, proc_pidinfo, proc_pid_rusage, proc_name
#include <sys/proc_info.h>      // proc_taskinfo, proc_taskallinfo
#include <sys/resource.h>       // rusage_info_current
#include <sys/sysctl.h>         // sysctl, sysctlbyname
#include <mach/mach.h>          // host_processor_info, host_statistics64
#include <mach/mach_time.h>     // mach_timebase_info, mach_continuous_time
#include <IOKit/IOKitLib.h>     // IOServiceMatching, IORegistryEntry* (SMC + block storage)

// --- Group 2: private IOHIDEventSystemClient API -----------------------------
// Apple Silicon temperature/fan sensors live behind AppleVendor HID services
// (PrimaryUsagePage 0xff00 / PrimaryUsage 0x0005). These functions are
// stable-in-practice but undocumented.
//
// macOS 26 reality: the SDK now ships public `hidsystem/IOHIDEventSystemClient.h`
// and `hidsystem/IOHIDServiceClient.h` that declare the opaque `*Ref` types as
// CF-bridged objects (so Swift manages their lifetime) plus a subset of the
// functions (`IOHIDEventSystemClientCopyServices`, `IOHIDServiceClientCopyProperty`).
// We include those headers so the *types* come from the SDK (single source of truth
// — re-typedef'ing them would make Swift mis-bridge create/copy memory rules), and
// hand-declare only the symbols the SDK still omits.

#include <IOKit/hidsystem/IOHIDEventSystemClient.h>  // IOHIDEventSystemClientRef (CF-bridged), CopyServices, CopyProperty
#include <IOKit/hidsystem/IOHIDServiceClient.h>       // IOHIDServiceClientRef (CF-bridged)

typedef struct __IOHIDEvent *IOHIDEventRef;

#ifdef __cplusplus
extern "C" {
#endif

// Still private (not in any SDK header):
IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service,
                                          int64_t type,
                                          int32_t options,
                                          int64_t timestamp);
double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

#ifdef __cplusplus
}
#endif

// Swift does not import function-like C macros, so expose the field-base computation
// as a static inline function the Swift side can call directly.
static inline int32_t MomoIOHIDEventFieldBase(int32_t type) { return type << 16; }

// HID event-type constants and the field-base macro. Not in any public SDK header.
#ifndef kIOHIDEventTypeTemperature
#define kIOHIDEventTypeTemperature 15
#endif
#ifndef kIOHIDEventTypePower
#define kIOHIDEventTypePower 25
#endif
#ifndef IOHIDEventFieldBase
#define IOHIDEventFieldBase(type) ((type) << 16)
#endif

#endif /* Momo_Bridging_Header_h */
