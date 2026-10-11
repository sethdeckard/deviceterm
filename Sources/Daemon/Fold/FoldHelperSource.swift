// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol

/// The guest-side program that sets a foldable simulator's hinge angle and
/// its orientation.
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
/// does reach it is the event its own virtualized driver listens for, on
/// usage page `0xFF61` usage `0x5B`.
///
/// **Orientation rides the same usage.** A foldable's UI ignores the
/// PurpleHID orientation event every other simulator takes: the device
/// orientation changes, but nothing re-lays out until the next fold. Device
/// Hub rotates one through this usage instead, with an
/// `orientation-picker-control` payload, and the UI follows at once.
///
/// **The payload must be an IOKit OSSerialize archive**, which is what
/// `IOCFSerialize` produces. A property-list serialization of the same
/// dictionary is accepted by every call on this path and then silently
/// ignored, so a mistake here looks like a working no-op rather than an
/// error.
enum FoldHelperSource {
    /// `usage: fold-helper hinge <angle>` (degrees in `0...180`) or
    /// `fold-helper orientation <portrait|pud|landscape-left|landscape-right>`.
    /// Prints nothing on success and a diagnostic on failure; the exit status
    /// is what the daemon reads.
    static let code = #"""
    // SPDX-License-Identifier: GPL-3.0-or-later
    // Guest-side hinge and orientation control for a foldable iOS simulator.
    // Compiled on demand by DeviceTerm; see FoldHelperSource.swift.
    #include <CoreFoundation/CoreFoundation.h>
    #include <mach/mach_time.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>

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

    // The virtualized driver's own vendor usage, shared by both controls.
    static const uint32_t kControlUsagePage = 0xFF61;
    static const uint32_t kControlUsage = 0x5B;
    // IOHIDEventSystemClientTypeSimple: no entitlement, and enough to
    // dispatch.
    static const int kClientTypeSimple = 4;

    static int usage(void) {
        fprintf(stderr,
            "usage: fold-helper hinge <angle 0-180>\n"
            "       fold-helper orientation "
            "<portrait|pud|landscape-left|landscape-right>\n");
        return 64;
    }

    // Serialize `payload` and post it on the driver's usage.
    static int dispatch(CFDictionaryRef payload) {
        IOHIDEventSystemClientRef client =
            IOHIDEventSystemClientCreateWithType(NULL, kClientTypeSimple, NULL);
        if (!client) {
            fprintf(stderr, "no HID event system client\n");
            return 70;
        }
        // OSSerialize, not a property list. A plist dispatches cleanly and
        // does nothing.
        CFDataRef archive = IOCFSerialize(payload, 1);
        if (!archive) {
            fprintf(stderr, "could not serialize the payload\n");
            return 70;
        }
        IOHIDEventRef event = IOHIDEventCreateVendorDefinedEvent(
            NULL, mach_absolute_time(), kControlUsagePage, kControlUsage, 0,
            CFDataGetBytePtr(archive), CFDataGetLength(archive), 0);
        if (!event) {
            fprintf(stderr, "could not build the event\n");
            return 70;
        }
        IOHIDEventSystemClientDispatchEvent(client, event);
        return 0;
    }

    static CFDictionaryRef makePayload(
        CFStringRef provider, CFStringRef source, CFStringRef type,
        CFTypeRef value) {
        const void *keys[] = {
            CFSTR("provider"), CFSTR("source"), CFSTR("type"), CFSTR("value")
        };
        const void *values[] = { provider, source, type, value };
        return CFDictionaryCreate(
            NULL, keys, values, 4,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    }

    static int hinge(const char *argument) {
        double degrees = atof(argument);
        if (degrees < 0.0 || degrees > 180.0) {
            fprintf(stderr, "angle out of range: %s\n", argument);
            return 64;
        }
        CFNumberRef value = CFNumberCreate(NULL, kCFNumberDoubleType, &degrees);
        return dispatch(makePayload(
            CFSTR("com.apple.Virtualization"), CFSTR("hinge-slider-control"),
            CFSTR("range"), value));
    }

    static int orientation(const char *argument) {
        // The values Device Hub's own orientation control sends.
        const char *accepted[] = {
            "portrait", "pud", "landscape-left", "landscape-right"
        };
        int known = 0;
        for (size_t i = 0; i < sizeof(accepted) / sizeof(accepted[0]); i++) {
            if (strcmp(argument, accepted[i]) == 0) known = 1;
        }
        if (!known) {
            fprintf(stderr, "unknown orientation: %s\n", argument);
            return 64;
        }
        CFStringRef value = CFStringCreateWithCString(
            NULL, argument, kCFStringEncodingUTF8);
        return dispatch(makePayload(
            CFSTR("com.apple.Virtualization.VirtualMachines"),
            CFSTR("orientation-picker-control"), CFSTR("enum"), value));
    }

    int main(int argc, char **argv) {
        if (argc != 3) return usage();
        if (strcmp(argv[1], "hinge") == 0) return hinge(argv[2]);
        if (strcmp(argv[1], "orientation") == 0) return orientation(argv[2]);
        return usage();
    }
    """#

    /// Arguments that set the hinge to `degrees`.
    static func hingeArguments(degrees: Double) -> [String] {
        ["hinge", String(degrees)]
    }

    /// Arguments that set the device orientation to `orientation`.
    static func orientationArguments(_ orientation: Orientation) -> [String] {
        ["orientation", orientationValue(orientation)]
    }

    /// The payload value Device Hub's orientation control sends for each
    /// device orientation.
    private static func orientationValue(_ orientation: Orientation) -> String {
        switch orientation {
        case .portrait:
            return "portrait"

        case .portraitUpsideDown:
            return "pud"

        case .landscapeLeft:
            return "landscape-left"

        case .landscapeRight:
            return "landscape-right"
        }
    }
}
