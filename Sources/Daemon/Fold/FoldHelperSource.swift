// SPDX-License-Identifier: GPL-3.0-or-later

/// The guest-side program that sets a foldable simulator's hinge angle.
///
/// Held as source rather than as a built artifact because it has to run
/// *inside* the simulator: it links the guest's IOKit and is an
/// arm64-iphonesimulator Mach-O, which nothing in a macOS app bundle can be.
/// `FoldHelperBuilder` compiles it on first use and caches the result, so the
/// distribution stays a pure macOS bundle with no foreign binary in its
/// signature and no second artifact to build at release time.
///
/// Held as a literal rather than a bundle resource because the daemon runs
/// both from an app bundle and straight out of `.build` during development,
/// and a resource would need a different lookup in each.
///
/// **Why a vendor-defined HID event.** The hinge is a sensor, and the guest
/// exposes no setter for it: there is no `simctl` or `devicectl` verb, and
/// none of SimulatorKit's Indigo builders carries a payload this shape. What
/// does reach it is the event its own virtualized hinge driver listens for,
/// on usage page `0xFF61` usage `0x5B`.
///
/// **The payload must be an IOKit OSSerialize archive**, which is what
/// `IOCFSerialize` produces. A property-list serialization of the same
/// dictionary is accepted by every call on this path and then silently
/// ignored, so a mistake here looks like a working no-op rather than an
/// error.
enum FoldHelperSource {
    /// `usage: fold-helper <angle>`, where angle is degrees in `0...180`.
    /// Prints nothing on success and a diagnostic on failure; the exit status
    /// is what the daemon reads.
    static let code = #"""
    // SPDX-License-Identifier: GPL-3.0-or-later
    // Guest-side hinge control for a foldable iOS simulator.
    // Compiled on demand by DeviceTerm; see FoldHelperSource.swift.
    #include <CoreFoundation/CoreFoundation.h>
    #include <mach/mach_time.h>
    #include <stdio.h>
    #include <stdlib.h>

    typedef struct __IOHIDEvent *IOHIDEventRef;
    typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

    extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreateWithType(
        CFAllocatorRef allocator, int type, CFDictionaryRef attributes);
    extern IOHIDEventRef IOHIDEventCreateVendorDefinedEvent(
        CFAllocatorRef allocator, uint64_t timestamp, uint32_t usagePage,
        uint32_t usage, uint32_t version, const uint8_t *data, CFIndex length,
        uint32_t options);
    extern void IOHIDEventSystemClientDispatchEvent(
        IOHIDEventSystemClientRef client, IOHIDEventRef event);
    extern CFDataRef IOCFSerialize(CFTypeRef object, CFOptionFlags options);

    // The hinge driver's own vendor usage.
    static const uint32_t kHingeUsagePage = 0xFF61;
    static const uint32_t kHingeUsage = 0x5B;
    // IOHIDEventSystemClientTypeSimple: no entitlement, and enough to
    // dispatch.
    static const int kClientTypeSimple = 4;

    int main(int argc, char **argv) {
        if (argc != 2) {
            fprintf(stderr, "usage: fold-helper <angle 0-180>\n");
            return 64;
        }
        double degrees = atof(argv[1]);
        if (degrees < 0.0 || degrees > 180.0) {
            fprintf(stderr, "angle out of range: %s\n", argv[1]);
            return 64;
        }

        IOHIDEventSystemClientRef client =
            IOHIDEventSystemClientCreateWithType(NULL, kClientTypeSimple, NULL);
        if (!client) {
            fprintf(stderr, "no HID event system client\n");
            return 70;
        }

        CFNumberRef value = CFNumberCreate(NULL, kCFNumberDoubleType, &degrees);
        const void *keys[] = {
            CFSTR("provider"), CFSTR("source"), CFSTR("type"), CFSTR("value")
        };
        const void *values[] = {
            CFSTR("com.apple.Virtualization"), CFSTR("hinge-slider-control"),
            CFSTR("range"), value
        };
        CFDictionaryRef payload = CFDictionaryCreate(
            NULL, keys, values, 4,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

        // OSSerialize, not a property list. A plist dispatches cleanly and
        // does nothing.
        CFDataRef archive = IOCFSerialize(payload, 1);
        if (!archive) {
            fprintf(stderr, "could not serialize the hinge payload\n");
            return 70;
        }

        IOHIDEventRef event = IOHIDEventCreateVendorDefinedEvent(
            NULL, mach_absolute_time(), kHingeUsagePage, kHingeUsage, 0,
            CFDataGetBytePtr(archive), CFDataGetLength(archive), 0);
        if (!event) {
            fprintf(stderr, "could not build the hinge event\n");
            return 70;
        }
        IOHIDEventSystemClientDispatchEvent(client, event);
        return 0;
    }
    """#
}
