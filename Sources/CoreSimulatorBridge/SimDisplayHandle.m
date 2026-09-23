// SPDX-License-Identifier: GPL-3.0-or-later

#import "SimDisplayHandle.h"
#import "CoreSimulatorLoader.h"

#import <CoreSimulator/SimServiceContext.h>
#import <CoreSimulator/SimDeviceSet.h>
#import <CoreSimulator/SimDevice.h>
#import <CoreSimulator/SimDeviceIO.h>
#import <CoreSimulator/SimDeviceIOProtocol-Protocol.h>
#import <CoreSimDeviceIO/SimDisplayIOSurfaceRenderable-Protocol.h>
#import <CoreSimDeviceIO/SimDisplayRenderable-Protocol.h>
#import <CoreSimDeviceIO/SimScreen-Protocol.h>

#import <objc/runtime.h>

static NSString *const kCSBErrorDomain = @"CoreSimulatorBridge.SimDisplayHandle";

typedef NS_ENUM(NSInteger, CSBDisplayHandleError) {
    CSBDisplayHandleErrorLoadFailed       = 20,
    CSBDisplayHandleErrorDeviceNotFound   = 21,
    CSBDisplayHandleErrorDeviceNotBooted  = 22,
    CSBDisplayHandleErrorNoIOPorts        = 23,
    CSBDisplayHandleErrorNoRenderable     = 24,
    CSBDisplayHandleErrorCallbackRegister = 25,
    CSBDisplayHandleErrorNoOrientation    = 26,
    CSBDisplayHandleErrorNotStarted       = 27,
};

// The display proxy's orientation surface. `SimScreen` and its registration
// methods come from the vendored `CoreSimDeviceIO/SimScreen-Protocol.h`, so
// the compiler checks those calls against the vendored protocol declaration
// rather than locally redeclared signatures. The two declarations below are
// what that header leaves out.
//
// `screenProperties` and the shape of what it returns: upstream names
// `SimScreenProperties` in prose but declares neither, because idb's own
// consumer ignores the properties callback. `CSBOrientationFromScreen` reads
// both, so both have to be declared here.
//
// Found by runtime introspection on macOS 26.5.2 / Xcode 26.6 against a
// booted iOS 26.5 device. The live `com.apple.framebuffer.display`
// descriptor conforms to `SimScreen` alongside the
// `SimDisplayIOSurfaceRenderable` the picker already selects on, so this is
// the same object, not a second lookup.
//
// `SimDisplayRotationAngleDelegate` / `didChangeDisplayAngle:` looks like
// the natural source and is **not** usable: it is declared in CoreSimDeviceIO
// but no port or descriptor vends it, and no proxy answers `displayAngle`.
@protocol CSBSimScreenProperties <NSObject>
@property (nonatomic, readonly) unsigned int uiOrientation;
/// Panel identity. `screenID` is the small integer `simctl io --display`
/// accepts; `uniqueId` is stable for a panel across a fold. A foldable
/// vends one display descriptor per panel, and these are what tell them
/// apart. The measured `displayClass`, `powerState` and `uiOrientation`
/// values do not: they are equal on both panels, and `uiOrientation`
/// tracks the device rather than the panel.
@property (nonatomic, readonly) unsigned int screenID;
@property (nonatomic, readonly, nullable) NSString *uniqueId;
@end

@protocol CSBSimScreen <SimScreen>
@property (nonatomic, readonly) id screenProperties;
@end

/// Map the display proxy's `uiOrientation` into the bridge's vocabulary.
///
/// `uiOrientation` is a `UIInterfaceOrientation`; `CSBDisplayOrientation`
/// (like `CSBDeviceOrientation`) is a `UIDeviceOrientation`. **The
/// landscape pair is swapped between the two**, because rotating the
/// device one way turns the interface the other way to compensate.
///
/// Pinned live, by rotating a device running an app that follows it:
///
///     device landscapeLeft  -> uiOrientation 4
///     device landscapeRight -> uiOrientation 3
///     device portrait       -> uiOrientation 1
///
/// The direction was confirmed against what the renderer already draws
/// correctly, not derived from the UIKit convention, since this swap is
/// exactly where a hand-derivation inverts without anything failing loudly.
static CSBDisplayOrientation CSBDisplayOrientationFromUIOrientation(unsigned int uiOrientation) {
    switch (uiOrientation) {
        case 1: return CSBDisplayOrientationPortrait;
        case 2: return CSBDisplayOrientationPortraitUpsideDown;
        case 3: return CSBDisplayOrientationLandscapeRight;
        case 4: return CSBDisplayOrientationLandscapeLeft;
        default: return CSBDisplayOrientationUnknown;
    }
}

/// Read the orientation a screen proxy is presenting.
///
/// Takes the proxy as an argument rather than reaching through the handle,
/// so the change callback can hold the one it registered against instead of
/// re-reading `self.renderable` on a queue that races `stop` clearing it.
static CSBDisplayOrientation CSBOrientationFromScreen(id<CSBSimScreen> screen) {
    if (!screen) return CSBDisplayOrientationUnknown;
    @try {
        id<CSBSimScreenProperties> props = screen.screenProperties;
        if (!props) return CSBDisplayOrientationUnknown;
        return CSBDisplayOrientationFromUIOrientation(props.uiOrientation);
    } @catch (NSException *e) {
        return CSBDisplayOrientationUnknown;
    }
}

/// The `SimScreenProperties` a display candidate vends, or nil. Mirrors
/// `_screen`'s `respondsToSelector:` test: ROCK proxies answer for
/// selectors they forward even when the protocol isn't in their
/// impersonated list.
static id<CSBSimScreenProperties> CSBPropertiesForCandidate(id candidate) {
    if (!candidate) return nil;
    @try {
        if ([candidate respondsToSelector:@selector(screenProperties)]) {
            return (id<CSBSimScreenProperties>)[(id<CSBSimScreen>)candidate screenProperties];
        }
    } @catch (NSException *e) {}
    return nil;
}

/// Whether a candidate's framebuffer has visible content, sampled on a
/// coarse grid.
///
/// A foldable powers one panel at a time, and the properties that would
/// name the lit one read the same on both. Content is what differs: every
/// sampled colour channel on the dark panel was zero in both measured
/// postures, and non-zero on the lit one.
///
/// This is a heuristic and a tiebreaker for the initial selection only. A
/// lit panel drawing black reads as dark here. `Unknown` means the surface
/// is missing or cannot be sampled, including invalid dimensions, a failed
/// lock, a missing base address, or insufficient row stride. It leaves the
/// caller on its existing ordering rather than guessing.
typedef NS_ENUM(NSInteger, CSBCandidateLuminance) {
    CSBCandidateLuminanceUnknown = 0,
    CSBCandidateLuminanceBlack,
    CSBCandidateLuminanceLit,
};

/// Up to ten sampling passes, sleeping 20ms between them while no candidate
/// reports content: 180ms of waiting at worst, since the first pass doesn't
/// sleep. Only spent on a multi-panel device where no candidate reports
/// content yet, which covers a guest that hasn't drawn its first frame.
static const NSUInteger kCSBLitPanelAttempts = 10;
static const NSTimeInterval kCSBLitPanelRetryInterval = 0.02;

static CSBCandidateLuminance CSBCandidateLuminanceOf(id candidate) {
    id surfaceObj = nil;
    @try {
        if ([candidate respondsToSelector:@selector(framebufferSurface)]) {
            surfaceObj = [(id<SimDisplayIOSurfaceRenderable>)candidate framebufferSurface];
        }
    } @catch (NSException *e) {}
    if (!surfaceObj) {
        @try {
            if ([candidate respondsToSelector:@selector(ioSurface)]) {
                surfaceObj = [(id<SimDisplayIOSurfaceRenderable>)candidate ioSurface];
            }
        } @catch (NSException *e) {}
    }
    if (!surfaceObj) return CSBCandidateLuminanceUnknown;

    IOSurfaceRef surface = (__bridge IOSurfaceRef)surfaceObj;
    size_t width = IOSurfaceGetWidth(surface);
    size_t height = IOSurfaceGetHeight(surface);
    if (width == 0 || height == 0) return CSBCandidateLuminanceUnknown;

    if (IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL) != kIOReturnSuccess) {
        return CSBCandidateLuminanceUnknown;
    }
    uint8_t *base = IOSurfaceGetBaseAddress(surface);
    size_t bytesPerRow = IOSurfaceGetBytesPerRow(surface);
    CSBCandidateLuminance result = CSBCandidateLuminanceBlack;
    if (!base || bytesPerRow < width * 4) {
        result = CSBCandidateLuminanceUnknown;
    } else {
        // Treat any non-zero sampled colour channel as evidence of content.
        // A coarse grid bounds the sampling work: stepping rather than
        // scanning keeps this cheap on a 2007x2853 surface.
        size_t stepX = MAX((size_t)1, width / 64);
        size_t stepY = MAX((size_t)1, height / 64);
        for (size_t y = 0; y < height && result == CSBCandidateLuminanceBlack; y += stepY) {
            for (size_t x = 0; x < width; x += stepX) {
                const uint8_t *pixel = base + y * bytesPerRow + x * 4;
                if (pixel[0] || pixel[1] || pixel[2]) {
                    result = CSBCandidateLuminanceLit;
                    break;
                }
            }
        }
    }
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    return result;
}

@interface SimDisplayHandle ()
@property (nonatomic, copy, readwrite) NSString *udid;
@property (nonatomic, strong, nullable) SimDevice *device;
@property (nonatomic, strong, nullable) NSUUID *callbackUUID;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, strong, nullable) NSUUID *screenCallbackUUID;
@property (nonatomic, assign, readwrite) unsigned int boundScreenID;
@property (nonatomic, copy, readwrite, nullable) NSString *boundScreenUniqueId;
@property (nonatomic, assign, readwrite) BOOL hasMultiplePanels;
/// Delivery queue for the screen callbacks, held so a rebind can re-register
/// them on the new panel without the caller registering again.
@property (nonatomic, strong, nullable) dispatch_queue_t screenCallbackQueue;

// Atomic, unlike the rest of these. CoreSimulator's delivery queues read all
// three while `stop` clears them from the owning thread, and a `nonatomic`
// getter hands back the value without retaining it, so the owner can release
// it between the load and the use. The atomic getter retains and autoreleases,
// which keeps it alive for that use. Delivery *after* `stop` returns is fine
// and expected: the pane's surface stream is already finished, and the
// coordinator's observer epoch discards a late orientation.
@property (atomic, strong, nullable) id<SimDisplayIOSurfaceRenderable> renderable;
@property (atomic, copy, nullable) CSBDisplaySurfaceCallback callback;
@property (atomic, copy, nullable) CSBDisplayOrientationCallback orientationCallback;

/// Which registration a surface delivery belongs to. Bumped on every
/// registration and captured by the blocks it installs, so a delivery from a
/// panel the handle has since moved off is dropped instead of forwarded.
/// Unregistering does not fence anything by itself: CoreSimulator can already
/// have a delivery in flight, and the surface it carries is the *old* panel's,
/// so without this a late arrival would push a dark frame over the one the
/// rebind just delivered.
///
/// Only ever read and written under `deliveryGate`.
@property (nonatomic, assign) uint64_t registrationGeneration;

/// Serialises surface delivery against rebinding.
///
/// Comparing the generation and invoking the callback have to be one step. A
/// bare atomic read leaves a window where an old panel's delivery passes the
/// check, stalls while the rebind publishes the new panel's first frame, then
/// resumes and hands over its stale surface anyway, leaving the pane dark
/// until the guest next draws. Holding this across the invocation closes it:
/// the rebind's generation bump and its initial delivery run here too, so a
/// late delivery is either wholly before the bump or rejected by it.
///
/// **Lock order.** This is the only lock a delivery takes. The daemon's
/// callback just hands the surface to a stream and returns; the fence that
/// drops a frame from a retired run runs later, in the pump that reads that
/// stream, so it is never held against this one. Nothing under this gate
/// waits on the lane queue that drives `rebindToLitPanel` either, which is
/// what keeps the two from deadlocking.
///
/// `stop` deliberately stays outside it. Teardown retires the consumer's
/// frame run *before* stopping the handle, so a delivery that races teardown
/// is dropped by that fence rather than published, and ordering it here would
/// buy nothing.
@property (nonatomic, strong) dispatch_queue_t deliveryGate;
@end

@implementation SimDisplayHandle

- (instancetype)init {
    self = [super init];
    if (self) {
        _deliveryGate = dispatch_queue_create("com.deviceterm.csb.display-delivery",
                                              DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

#pragma mark Lookup

+ (nullable SimServiceContext *)_serviceContextWithError:(NSError **)error {
    Class ctxCls = NSClassFromString(@"SimServiceContext");
    if (!ctxCls) return nil;
    NSString *devDir = [CoreSimulatorLoader resolveDeveloperDir];
    NSError *inner = nil;
    SimServiceContext *ctx = [ctxCls sharedServiceContextForDeveloperDir:devDir error:&inner];
    if (!ctx && error) *error = inner;
    return ctx;
}

+ (nullable instancetype)handleForUDID:(NSString *)udid error:(NSError **)error {
    if (![CoreSimulatorLoader loadWithError:error]) {
        if (error && *error) {
            *error = [NSError errorWithDomain:kCSBErrorDomain
                                         code:CSBDisplayHandleErrorLoadFailed
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"CoreSimulator framework load failed",
                NSUnderlyingErrorKey: *error,
            }];
        }
        return nil;
    }
    SimServiceContext *ctx = [self _serviceContextWithError:error];
    if (!ctx) return nil;
    NSError *inner = nil;
    SimDeviceSet *set = [ctx defaultDeviceSetWithError:&inner];
    if (!set) {
        if (error) *error = inner;
        return nil;
    }

    NSString *needle = udid.lowercaseString;
    for (SimDevice *dev in set.devices) {
        if ([dev.UDID.UUIDString.lowercaseString isEqualToString:needle]) {
            SimDisplayHandle *handle = [SimDisplayHandle new];
            handle.udid = udid;
            handle.device = dev;
            handle.callbackUUID = [NSUUID UUID];
            return handle;
        }
    }
    if (error) {
        *error = [NSError errorWithDomain:kCSBErrorDomain
                                     code:CSBDisplayHandleErrorDeviceNotFound
                                 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Device with UDID %@ not found", udid],
        }];
    }
    return nil;
}

- (void)dealloc {
    [self stop];
}

#pragma mark Picker (reverse-engineered truth, preserve)

/// Every proxy that could be a display. CoreSimulator exposes several that
/// conform to `SimDisplayIOSurfaceRenderable` per device, and two things
/// about how they present have to be handled here:
///
///   - Conformance can be carried by either the port or its
///     `port.descriptor`; enumerate both.
///   - Conformance can be claimed via the protocol *or* by responding to
///     either callback selector shape; check both.
///
/// Choosing between what this returns is `_findRenderableWithError:`.
- (nullable NSArray<id<SimDisplayIOSurfaceRenderable>> *)_candidatesWithError:(NSError **)error {
    SimDevice *device = self.device;
    id ioObj = device.io;
    if (!ioObj) {
        if (error) {
            *error = [NSError errorWithDomain:kCSBErrorDomain
                                         code:CSBDisplayHandleErrorDeviceNotBooted
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"device.io is nil; is the device booted?",
            }];
        }
        return nil;
    }
    NSArray *ports = nil;
    if ([ioObj respondsToSelector:@selector(ioPorts)]) {
        ports = [ioObj performSelector:@selector(ioPorts)];
    }
    if (ports.count == 0) {
        if (error) {
            *error = [NSError errorWithDomain:kCSBErrorDomain
                                         code:CSBDisplayHandleErrorNoIOPorts
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"No IO ports; device may not be fully booted yet",
            }];
        }
        return nil;
    }

    NSMutableArray<id<SimDisplayIOSurfaceRenderable>> *candidates = [NSMutableArray array];
    for (id port in ports) {
        id desc = nil;
        if ([port respondsToSelector:@selector(descriptor)]) {
            desc = [port performSelector:@selector(descriptor)];
        }
        NSArray *pair = desc ? @[port, desc] : @[port];
        for (id candidate in pair) {
            BOOL viaProtocol = [candidate conformsToProtocol:@protocol(SimDisplayIOSurfaceRenderable)];
            BOOL viaPluralSelector = [candidate respondsToSelector:
                @selector(registerCallbackWithUUID:ioSurfacesChangeCallback:)];
            BOOL viaSingularSelector = [candidate respondsToSelector:
                @selector(registerCallbackWithUUID:ioSurfaceChangeCallback:)];
            if (viaProtocol || viaPluralSelector || viaSingularSelector) {
                [candidates addObject:(id<SimDisplayIOSurfaceRenderable>)candidate];
            }
        }
    }

    if (candidates.count == 0) {
        if (error) {
            *error = [NSError errorWithDomain:kCSBErrorDomain
                                         code:CSBDisplayHandleErrorNoRenderable
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"No port conforms to SimDisplayIOSurfaceRenderable",
            }];
        }
        return nil;
    }
    return candidates;
}

/// The candidates that report a non-zero `displaySize`, which is what being
/// bound to a screen looks like. A foldable vends one per panel.
static NSArray<id<SimDisplayIOSurfaceRenderable>> *CSBSizedCandidates(NSArray *candidates) {
    NSMutableArray<id<SimDisplayIOSurfaceRenderable>> *sized = [NSMutableArray array];
    for (id<SimDisplayIOSurfaceRenderable> candidate in candidates) {
        CGSize size = CGSizeZero;
        @try {
            id untyped = candidate;
            if ([untyped respondsToSelector:@selector(displaySize)]) {
                size = [untyped displaySize];
            }
        } @catch (NSException *e) {}
        if (size.width > 0 && size.height > 0) {
            [sized addObject:candidate];
        }
    }
    return sized;
}

/// Pick the renderable to mirror, out of everything the device vends.
///
///   - Prefer candidates with non-zero `displaySize`. If none has a size
///     (shouldn't happen on a booted device, but defensive), fall back to
///     the first conformer.
///   - When several have a size, sample their content to choose a panel;
///     otherwise fall back to enumeration order.
- (nullable id<SimDisplayIOSurfaceRenderable>)_findRenderableWithError:(NSError **)error {
    NSArray<id<SimDisplayIOSurfaceRenderable>> *candidates = [self _candidatesWithError:error];
    if (!candidates) return nil;

    // Prefer a renderable with non-zero displaySize. Fall back to the first
    // conformer if none has a size yet (early boot transient).
    NSArray<id<SimDisplayIOSurfaceRenderable>> *sized = CSBSizedCandidates(candidates);
    self.hasMultiplePanels = sized.count > 1;

    // At most one sized candidate: choose it, or fall back to the first
    // conformer. A foldable vends one per panel, both sized, and
    // enumeration order does not say which is lit, so several sized
    // candidates fall through to the content tiebreaker below.
    if (sized.count <= 1) {
        id<SimDisplayIOSurfaceRenderable> chosen = sized.firstObject ?: candidates.firstObject;
        [self _recordBoundPanelFor:chosen];
        return chosen;
    }

    // Attaching during boot can beat the guest drawing its first frame, and
    // a no-content read then means "too early", not "this panel is dark".
    // Nothing revisits this on its own, so a wrong answer here costs a blank
    // pane until a caller drives `rebindToLitPanel`. Worth a bounded wait to
    // avoid.
    id<SimDisplayIOSurfaceRenderable> lit = nil;
    for (NSUInteger attempt = 0; attempt < kCSBLitPanelAttempts && !lit; attempt++) {
        if (attempt > 0) {
            [NSThread sleepForTimeInterval:kCSBLitPanelRetryInterval];
        }
        for (id<SimDisplayIOSurfaceRenderable> candidate in sized) {
            if (CSBCandidateLuminanceOf(candidate) == CSBCandidateLuminanceLit) {
                lit = candidate;
                break;
            }
        }
    }
    // No candidate reported sampled content in that window, so take the
    // first sized candidate. Zero samples do not prove the whole surface is
    // black; missing or unreadable surfaces also take this fallback.
    // `rebindToLitPanel` is what corrects a guess that lands here, once some
    // panel is drawing.
    id<SimDisplayIOSurfaceRenderable> chosen = lit ?: sized.firstObject;
    [self _recordBoundPanelFor:chosen];
    return chosen;
}

/// Capture the identity of the panel the picker settled on, so a consumer
/// can name it, re-resolve it, or notice it changed. Best-effort: a proxy
/// that vends no `SimScreenProperties` leaves the fields at their
/// "unknown" values rather than failing the bind.
- (void)_recordBoundPanelFor:(nullable id)candidate {
    id<CSBSimScreenProperties> props = CSBPropertiesForCandidate(candidate);
    if (!props) {
        self.boundScreenID = 0;
        self.boundScreenUniqueId = nil;
        return;
    }
    @try {
        self.boundScreenID = props.screenID;
        self.boundScreenUniqueId = props.uniqueId;
    } @catch (NSException *e) {
        self.boundScreenID = 0;
        self.boundScreenUniqueId = nil;
    }
}

/// A candidate's stable panel identity, or nil when it vends no
/// `SimScreenProperties`. Two candidates with no identity cannot be told
/// apart, which is why an empty answer disqualifies one from a rebind.
static NSString *CSBUniqueIdForCandidate(id candidate) {
    id<CSBSimScreenProperties> props = CSBPropertiesForCandidate(candidate);
    if (!props) return nil;
    @try {
        return props.uniqueId;
    } @catch (NSException *e) {
        return nil;
    }
}

- (BOOL)rebindToLitPanel {
    if (!self.running) return NO;
    // An earlier attempt can have left observation wanted but unregistered,
    // on this panel or the one it rolled back from. Retry it before looking
    // for a swap, so each call is also an attempt to get it back.
    if (self.screenCallbackQueue && !self.screenCallbackUUID) {
        [self _registerScreenCallbacksWithError:NULL];
    }
    id<SimDisplayIOSurfaceRenderable> current = self.renderable;
    NSString *boundId = self.boundScreenUniqueId;
    if (!current || boundId.length == 0) return NO;
    // Leaving a panel that still has content would fight the picker rather
    // than follow the fold, and during a fold there is a window where the old
    // panel has gone dark before the new one lights. Both read as "not yet".
    if (CSBCandidateLuminanceOf(current) != CSBCandidateLuminanceBlack) return NO;

    NSArray<id<SimDisplayIOSurfaceRenderable>> *sized =
        CSBSizedCandidates([self _candidatesWithError:NULL]);
    if (sized.count <= 1) return NO;

    id<SimDisplayIOSurfaceRenderable> lit = nil;
    for (id<SimDisplayIOSurfaceRenderable> candidate in sized) {
        NSString *candidateId = CSBUniqueIdForCandidate(candidate);
        if (candidateId.length == 0 || [candidateId isEqualToString:boundId]) continue;
        if (CSBCandidateLuminanceOf(candidate) != CSBCandidateLuminanceLit) continue;
        // More than one lit panel is not a posture this device has, so treat
        // it as a reading to discard rather than a choice to make.
        if (lit) return NO;
        lit = candidate;
    }
    if (!lit) return NO;

    // Whether the caller *wants* observation, which is not the same as having
    // it: `screenCallbackUUID` goes nil on a registration that failed, and
    // reading intent from it would let the next attempt quietly decide
    // observation was never wanted and report success without it.
    BOOL wantsScreenCallbacks = (self.screenCallbackQueue != nil);
    // Order matters: `_screen` reads `renderable`, so the screen callbacks
    // have to come off the old panel before the binding moves.
    [self _unregisterSurfaceCallbacksOn:current];
    [self _unregisterScreenCallbacks];

    self.renderable = lit;
    [self _recordBoundPanelFor:lit];
    BOOL bound = [self _registerSurfaceCallbacksOn:lit];
    // Orientation observation has to move with the binding. Screen callbacks
    // are the only thing that makes a later fold noticeable, so a handle that
    // kept the new panel without them would show the right picture now and
    // never follow another fold.
    if (bound && wantsScreenCallbacks) {
        bound = [self _registerScreenCallbacksWithError:NULL];
        if (!bound) [self _unregisterSurfaceCallbacksOn:lit];
    }
    if (!bound) {
        // Put it back on the panel that was working. That panel is dark, so
        // the pane stays blank, but the caller is polling and its remaining
        // attempts check again for a swap. Re-applying the old panel's
        // registrations is best effort, and only missing screen observation
        // is retried later. Staying on the new panel half-registered would
        // instead leave the pane correct and stuck.
        self.renderable = current;
        [self _recordBoundPanelFor:current];
        [self _registerSurfaceCallbacksOn:current];
        if (wantsScreenCallbacks) [self _registerScreenCallbacksWithError:NULL];
        return NO;
    }

    // An idle guest can go seconds without drawing, so hand over the newly
    // bound surface now rather than leaving the consumer on the old panel's
    // last frame. Under the gate, so a delivery the bump above rejected can
    // never land after this one. +1 retained; balance it once consumed.
    IOSurfaceRef ref = [self currentSurface];
    if (ref) {
        dispatch_sync(self.deliveryGate, ^{
            CSBDisplaySurfaceCallback cb = self.callback;
            if (cb) cb(ref);
        });
        CFRelease(ref);
    }
    return YES;
}

#pragma mark Start / stop

/// Register the surface and damage callbacks on `renderable` under this
/// handle's callback UUID. Returns NO when the proxy answers neither
/// `registerCallbackWithUUID:` IOSurface shape. The damage-rectangles
/// registration is attempted independently of that answer, so it can be left
/// in place even when this returns NO.
///
/// Both blocks reach the live callback through the handle rather than
/// capturing it, so they stay correct across a `start` that replaces the
/// callback and a rebind that moves them to another panel.
- (BOOL)_registerSurfaceCallbacksOn:(id<SimDisplayIOSurfaceRenderable>)renderable {
    __weak SimDisplayHandle *weakSelf = self;
    // Fences every block installed here against a later registration. Taken
    // under the gate so a delivery cannot straddle the bump.
    __block uint64_t generation = 0;
    dispatch_sync(self.deliveryGate, ^{
        generation = self.registrationGeneration + 1;
        self.registrationGeneration = generation;
    });

    // Surface-change callback. CoreSimulator delivers either an
    // xpc_object (Xcode 8 era) or an IOSurface object (Xcode 9+); both
    // are toll-free-bridgeable to IOSurfaceRef. We pass the source
    // surface straight through. The caller (`PaneCoordinator` via
    // `RetainedSurface`) increments the use count + retains the ref
    // before the callback returns, so the source ref's lifetime is
    // safely extended across the marshalling boundary.
    void (^surfaceCallback)(id) = ^(id surface) {
        SimDisplayHandle *strong = weakSelf;
        if (!strong) return;
        IOSurfaceRef ref = surface ? (__bridge IOSurfaceRef)surface : NULL;
        if (!ref) return;
        // This one carries the surface rather than reading it back, so a
        // delivery that outlived its registration would hand over a panel the
        // handle no longer mirrors. Checking and forwarding under the gate is
        // what makes the rejection stick.
        dispatch_sync(strong.deliveryGate, ^{
            if (strong.registrationGeneration != generation) return;
            CSBDisplaySurfaceCallback cb = strong.callback;
            if (cb) cb(ref);
        });
    };

    // Damage-rectangles callback: registering it is the load-bearing
    // side effect: on iOS 26.4 the proxy doesn't allocate its IOSurface
    // until *some* damage callback exists. When it fires we
    // opportunistically re-pull the current surface to catch the first
    // frame even if the dedicated IOSurface callbacks haven't fired yet.
    // `currentSurface` returns a +1 retained ref; balance the +1 with
    // a CFRelease after the callback returns (the callback's own
    // RetainedSurface wrapper bumps the count again for its lifetime).
    void (^damageCallback)(NSArray *) = ^(NSArray *_unused) {
        SimDisplayHandle *strong = weakSelf;
        if (!strong) return;
        IOSurfaceRef ref = [strong currentSurface];
        if (!ref) return;
        dispatch_sync(strong.deliveryGate, ^{
            if (strong.registrationGeneration != generation) return;
            CSBDisplaySurfaceCallback cb = strong.callback;
            if (cb) cb(ref);
        });
        CFRelease(ref);
    };

    BOOL registered = NO;
    if ([renderable respondsToSelector:@selector(registerCallbackWithUUID:ioSurfacesChangeCallback:)]) {
        [renderable registerCallbackWithUUID:self.callbackUUID
                    ioSurfacesChangeCallback:surfaceCallback];
        registered = YES;
    }
    if ([renderable respondsToSelector:@selector(registerCallbackWithUUID:ioSurfaceChangeCallback:)]) {
        [renderable registerCallbackWithUUID:self.callbackUUID
                     ioSurfaceChangeCallback:surfaceCallback];
        registered = YES;
    }
    id renderableUntyped = renderable;
    if ([renderableUntyped respondsToSelector:@selector(registerCallbackWithUUID:damageRectanglesCallback:)]) {
        [renderableUntyped registerCallbackWithUUID:self.callbackUUID
                            damageRectanglesCallback:damageCallback];
    }
    return registered;
}

/// Drop this handle's surface and damage registrations from `renderable`.
/// Repeated start/stop and rebind cycles otherwise leak block registrations
/// into CoreSimulator that live until the proxy goes away.
- (void)_unregisterSurfaceCallbacksOn:(nullable id<SimDisplayIOSurfaceRenderable>)renderable {
    if (!renderable) return;
    if ([renderable respondsToSelector:@selector(unregisterIOSurfacesChangeCallbackWithUUID:)]) {
        [renderable unregisterIOSurfacesChangeCallbackWithUUID:self.callbackUUID];
    }
    if ([renderable respondsToSelector:@selector(unregisterIOSurfaceChangeCallbackWithUUID:)]) {
        [renderable unregisterIOSurfaceChangeCallbackWithUUID:self.callbackUUID];
    }
    id renderableUntyped = renderable;
    if ([renderableUntyped respondsToSelector:@selector(unregisterDamageRectanglesCallbackWithUUID:)]) {
        [renderableUntyped unregisterDamageRectanglesCallbackWithUUID:self.callbackUUID];
    }
}

- (BOOL)startWithCallback:(CSBDisplaySurfaceCallback)callback
                    error:(NSError **)error {
    self.callback = callback;
    if (self.running) {
        // Replace the callback in place; CoreSimulator registration stays.
        return YES;
    }

    NSError *inner = nil;
    id<SimDisplayIOSurfaceRenderable> renderable = [self _findRenderableWithError:&inner];
    if (!renderable) {
        if (error) *error = inner;
        return NO;
    }
    self.renderable = renderable;

    if (![self _registerSurfaceCallbacksOn:renderable]) {
        if (error) {
            *error = [NSError errorWithDomain:kCSBErrorDomain
                                         code:CSBDisplayHandleErrorCallbackRegister
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"Renderable lacks any registerCallbackWithUUID: shape",
            }];
        }
        self.renderable = nil;
        return NO;
    }

    self.running = YES;

    // Fire synchronously with whatever surface is already bound, so
    // consumers don't have to wait for the first change event.
    // `currentSurface` returns +1 retained; balance with CFRelease
    // after the callback has consumed it (the callback's
    // RetainedSurface wrapper bumps the count again for its
    // lifetime).
    IOSurfaceRef initial = [self currentSurface];
    if (initial) {
        callback(initial);
        CFRelease(initial);
    }

    return YES;
}

/// The renderable's current IOSurface, or NULL. Returns a **+1 retained**
/// ref: the source object CoreSimulator hands back is typically
/// autoreleased, so a bare `(__bridge IOSurfaceRef)` would dangle the
/// moment the caller's autorelease pool drained. `CFRetain` before
/// return; caller balances with `CFRelease` (Swift's CF bridging does
/// this automatically). The strong `surface` local is held until
/// after the `CFRetain` returns so ARC can't drain the autoreleased
/// reference mid-call.
- (nullable IOSurfaceRef)currentSurface {
    id<SimDisplayIOSurfaceRenderable> renderable = self.renderable;
    if (!renderable) return NULL;
    id surface = nil;
    @try {
        if ([renderable respondsToSelector:@selector(framebufferSurface)]) {
            surface = renderable.framebufferSurface;
        }
    } @catch (NSException *e) {}
    if (!surface) {
        @try {
            if ([renderable respondsToSelector:@selector(ioSurface)]) {
                surface = renderable.ioSurface;
            }
        } @catch (NSException *e) {}
    }
    if (!surface) return NULL;
    IOSurfaceRef ref = (__bridge IOSurfaceRef)surface;
    CFRetain(ref);
    return ref;
}

- (CGSize)displaySize {
    id<SimDisplayIOSurfaceRenderable> renderable = self.renderable;
    if (!renderable) return CGSizeZero;
    id untyped = renderable;
    @try {
        if ([untyped respondsToSelector:@selector(displaySize)]) {
            return [untyped displaySize];
        }
    } @catch (NSException *e) {}
    return CGSizeZero;
}

#pragma mark Orientation

/// The live display proxy as a `SimScreen`, or nil when it doesn't vend
/// one. `respondsToSelector:` is the test rather than `conformsToProtocol:`
/// because the ROCK proxies answer for selectors they forward even when the
/// protocol isn't in their impersonated list.
- (nullable id<CSBSimScreen>)_screen {
    id renderable = self.renderable;
    if (!renderable) return nil;
    @try {
        if ([renderable respondsToSelector:@selector(screenProperties)]) {
            return (id<CSBSimScreen>)renderable;
        }
    } @catch (NSException *e) {}
    return nil;
}

/// Reads `renderable`, so it is for the owning (coordinator) thread only,
/// the same one that calls `start` / `stop`. The change callback must not
/// use it; it holds its own proxy reference instead.
- (CSBDisplayOrientation)currentDisplayOrientation {
    return CSBOrientationFromScreen([self _screen]);
}

- (BOOL)startOrientationWithCallback:(CSBDisplayOrientationCallback)callback
                               queue:(dispatch_queue_t)queue
                               error:(NSError **)error {
    if (!self.running) {
        if (error) {
            *error = [NSError errorWithDomain:kCSBErrorDomain
                                         code:CSBDisplayHandleErrorNotStarted
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"start(callback:) must succeed before observing orientation",
            }];
        }
        return NO;
    }
    id<CSBSimScreen> screen = [self _screen];
    if (!screen) {
        if (error) {
            *error = [NSError errorWithDomain:kCSBErrorDomain
                                         code:CSBDisplayHandleErrorNoOrientation
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"Display proxy vends no orientation source",
            }];
        }
        return NO;
    }
    if (self.screenCallbackUUID) {
        // Replace the callback in place, as `start` does for surfaces.
        self.orientationCallback = callback;
        return YES;
    }

    self.orientationCallback = callback;
    self.screenCallbackQueue = queue;
    if (![self _registerScreenCallbacksWithError:error]) {
        self.orientationCallback = nil;
        self.screenCallbackQueue = nil;
        return NO;
    }
    return YES;
}

/// Register screen callbacks on the currently bound screen, under a fresh
/// UUID stored in `screenCallbackUUID`. Returns NO when the proxy vends no
/// screen or the registration throws.
///
/// Separate from `startOrientationWithCallback:queue:` so a rebind can move
/// the registration to the new panel without the caller registering again.
- (BOOL)_registerScreenCallbacksWithError:(NSError **)error {
    id<CSBSimScreen> screen = [self _screen];
    dispatch_queue_t queue = self.screenCallbackQueue;
    if (!screen || !queue) {
        if (error) {
            *error = [NSError errorWithDomain:kCSBErrorDomain
                                         code:CSBDisplayHandleErrorNoOrientation
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"Display proxy vends no orientation source",
            }];
        }
        return NO;
    }
    NSUUID *uuid = [NSUUID UUID];

    __weak SimDisplayHandle *weakSelf = self;
    // Re-read `screenProperties` instead of using the callback argument.
    // `SimScreen` declares the argument as `id`, and ROCKRemoteProxy provides
    // no stronger runtime type. Re-reading also makes observation
    // level-triggered, so coalesced changes settle on the current value.
    //
    // Read them through the captured `screen`, never `self.renderable`.
    // Deliveries after `stopOrientation` are expected, and `stop` clears
    // `renderable` from the owning thread, so reaching back through the
    // handle would be a use-after-free waiting for the right interleaving.
    // The block owns a strong reference for exactly as long as it is
    // registered, which is what makes the access safe.
    //
    // No dedupe here on purpose. `propertiesChanged` covers every screen
    // property, so most deliveries aren't rotations and the consumer sees
    // repeats. Keeping a baseline in the bridge would have to be seeded, and
    // any seed races the callbacks it is meant to be compared against: seed
    // late and the first real rotation reads as "no change" and is swallowed
    // for good. The consumer already holds the authoritative previous value,
    // so it dedupes without a race.
    void (^propertiesChanged)(id) = ^(id properties) {
        CSBDisplayOrientation now = CSBOrientationFromScreen(screen);
        // Unknown means the source went away or reported something with no
        // pane meaning; the consumer's last good value stands rather than
        // the pane flipping to a guess.
        if (now == CSBDisplayOrientationUnknown) return;
        SimDisplayHandle *strong = weakSelf;
        if (!strong) return;
        CSBDisplayOrientationCallback cb = strong.orientationCallback;
        if (cb) cb(now);
    };

    // All three blocks must be non-nil. Passing nil for the ones we don't
    // want **kills the simulator**: CoreSimulator invokes them
    // unconditionally, so the first frame after registration dereferences
    // NULL and takes the device down with it. See the display-orientation
    // section of `as-tested.md`.
    @try {
        [screen registerScreenCallbacksWithUUID:uuid
                                  callbackQueue:queue
                                  frameCallback:^{}
                        surfacesChangedCallback:^(id _Nullable surface,
                                                  id _Nullable maskedSurface) {}
                      propertiesChangedCallback:propertiesChanged];
    } @catch (NSException *e) {
        if (error) {
            *error = [NSError errorWithDomain:kCSBErrorDomain
                                         code:CSBDisplayHandleErrorNoOrientation
                                     userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:
                    @"Registering screen callbacks failed: %@", e.reason ?: @"(no reason)"],
            }];
        }
        return NO;
    }
    self.screenCallbackUUID = uuid;
    return YES;
}

/// Drop the screen-callback registration from the currently bound screen,
/// leaving `orientationCallback` and `screenCallbackQueue` in place so a
/// rebind can register again. Idempotent.
- (void)_unregisterScreenCallbacks {
    NSUUID *uuid = self.screenCallbackUUID;
    if (!uuid) return;
    self.screenCallbackUUID = nil;
    id<CSBSimScreen> screen = [self _screen];
    @try {
        [screen unregisterScreenCallbacksWithUUID:uuid];
    } @catch (NSException *e) {}
}

- (void)stopOrientation {
    self.orientationCallback = nil;
    [self _unregisterScreenCallbacks];
    self.screenCallbackQueue = nil;
}

#pragma mark Stop

- (void)stop {
    self.callback = nil;
    [self stopOrientation];
    if (!self.running) return;
    self.running = NO;
    [self _unregisterSurfaceCallbacksOn:self.renderable];
    self.renderable = nil;
}

@end
