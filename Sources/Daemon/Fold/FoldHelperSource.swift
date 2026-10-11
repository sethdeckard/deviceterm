// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol

/// The guest-side program that sets a foldable simulator's hinge angle and
/// its orientation, and watches the hinge.
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
/// **Reading the hinge happens in the guest too.** CoreMotion's
/// `CoreMotion_DeviceStateRelay_Crane` service emits a hinge event (IOHIDEvent
/// type 44, the angle at field index 1) on every change, whoever made it, and
/// answers a copy of its current one. A monitor client reads both with no
/// entitlement. This is the fallback for a host whose `devicectl` lacks
/// `device motion hinge-angle`, as the Xcode 27.1 RC's does
/// (`HingeReaderSource`).
///
/// **The payload must be an IOKit OSSerialize archive**, which is what
/// `IOCFSerialize` produces. A property-list serialization of the same
/// dictionary is accepted by every call on this path and then silently
/// ignored, so a mistake here looks like a working no-op rather than an
/// error.
enum FoldHelperSource {
    /// `usage: fold-helper hinge <angle>` (degrees in `0...180`),
    /// `fold-helper orientation <portrait|pud|landscape-left|landscape-right>`,
    /// or `fold-helper watch`.
    ///
    /// `hinge` and `orientation` print nothing on success and a diagnostic on
    /// failure; the exit status is what the daemon reads. `watch` prints
    /// `angle <degrees>` for the current angle when a valid current hinge event
    /// is available, then once per valid hinge event, and runs until it is
    /// terminated or its output goes away.
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
    typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
    typedef void (*IOHIDEventCallback)(
        void *target, void *refcon, IOHIDServiceClientRef service,
        IOHIDEventRef event);

    extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreateWithType(
        CFAllocatorRef allocator, int type, CFDictionaryRef attributes);
    extern IOHIDEventRef IOHIDEventCreateVendorDefinedEvent(
        CFAllocatorRef allocator, uint64_t timestamp, uint32_t usagePage,
        uint32_t usage, uint32_t version, const uint8_t *data, CFIndex length,
        uint32_t options);
    extern void IOHIDEventSystemClientDispatchEvent(
        IOHIDEventSystemClientRef client, IOHIDEventRef event);
    extern CFDataRef IOCFSerialize(CFTypeRef object, CFOptionFlags options);
    extern CFArrayRef IOHIDEventSystemClientCopyServices(
        IOHIDEventSystemClientRef client);
    extern IOHIDEventRef IOHIDServiceClientCopyEvent(
        IOHIDServiceClientRef service, int64_t type, IOHIDEventRef matching,
        uint64_t options);
    extern void IOHIDEventSystemClientScheduleWithRunLoop(
        IOHIDEventSystemClientRef client, CFRunLoopRef runLoop,
        CFStringRef mode);
    extern void IOHIDEventSystemClientRegisterEventCallback(
        IOHIDEventSystemClientRef client, IOHIDEventCallback callback,
        void *target, void *refcon);
    extern uint32_t IOHIDEventGetType(IOHIDEventRef event);
    extern double IOHIDEventGetFloatValue(IOHIDEventRef event, uint32_t field);

    // The virtualized driver's own vendor usage, shared by both controls.
    static const uint32_t kControlUsagePage = 0xFF61;
    static const uint32_t kControlUsage = 0x5B;
    // IOHIDEventSystemClientTypeSimple: no entitlement, and enough to
    // dispatch.
    static const int kClientTypeSimple = 4;
    // IOHIDEventSystemClientTypeMonitor: sees every service's events, and
    // needs no entitlement in the simulator.
    static const int kClientTypeMonitor = 1;
    // The hinge event CoreMotion's Crane service emits, and its angle field.
    static const uint32_t kHingeEventType = 44;
    static const uint32_t kHingeAngleField = (kHingeEventType << 16) | 1;

    static int usage(void) {
        fprintf(stderr,
            "usage: fold-helper hinge <angle 0-180>\n"
            "       fold-helper orientation "
            "<portrait|pud|landscape-left|landscape-right>\n"
            "       fold-helper watch\n");
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

    // Print a hinge event's angle. A value the daemon could not use is
    // skipped here rather than sent.
    static void printAngle(IOHIDEventRef event) {
        double degrees = IOHIDEventGetFloatValue(event, kHingeAngleField);
        if (!(degrees >= 0.0 && degrees <= 180.0)) return;
        printf("angle %.1f\n", degrees);
        fflush(stdout);
    }

    static void hingeEvent(
        void *target, void *refcon, IOHIDServiceClientRef service,
        IOHIDEventRef event) {
        if (IOHIDEventGetType(event) == kHingeEventType) printAngle(event);
    }

    // Report the current angle, then every change, until terminated. A write
    // after the daemon has gone raises SIGPIPE, which ends this too.
    //
    // Subscribe before taking the snapshot. Events are delivered only once the
    // run loop runs, after the snapshot is printed, so a change in between
    // arrives after it rather than being lost.
    static int watch(void) {
        IOHIDEventSystemClientRef client =
            IOHIDEventSystemClientCreateWithType(NULL, kClientTypeMonitor, NULL);
        if (!client) {
            fprintf(stderr, "no HID event system client\n");
            return 70;
        }
        IOHIDEventSystemClientScheduleWithRunLoop(
            client, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        IOHIDEventSystemClientRegisterEventCallback(client, hingeEvent, NULL, NULL);
        CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
        if (services) {
            for (CFIndex i = 0; i < CFArrayGetCount(services); i++) {
                IOHIDServiceClientRef service =
                    (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
                IOHIDEventRef current =
                    IOHIDServiceClientCopyEvent(service, kHingeEventType, NULL, 0);
                if (current && IOHIDEventGetType(current) == kHingeEventType) {
                    printAngle(current);
                    break;
                }
            }
        }
        CFRunLoopRun();
        return 0;
    }

    int main(int argc, char **argv) {
        if (argc == 2 && strcmp(argv[1], "watch") == 0) return watch();
        if (argc != 3) return usage();
        if (strcmp(argv[1], "hinge") == 0) return hinge(argv[2]);
        if (strcmp(argv[1], "orientation") == 0) return orientation(argv[2]);
        return usage();
    }
    """#

    /// Arguments that watch the hinge, printing `angle <degrees>` lines.
    static let watchArguments = ["watch"]

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
