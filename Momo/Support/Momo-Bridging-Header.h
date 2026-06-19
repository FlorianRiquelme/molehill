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
// (PrimaryUsagePage 0xff00 / PrimaryUsage 0x0005). These opaque refs and
// functions are stable-in-practice but undocumented.

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

#ifdef __cplusplus
extern "C" {
#endif

IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef key);
IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service,
                                          int64_t type,
                                          int32_t options,
                                          int64_t timestamp);
double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

#ifdef __cplusplus
}
#endif

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
