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
@end

@implementation SimDisplayHandle

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

/// Multi-renderable picker. CoreSimulator exposes multiple proxies that
/// conform to `SimDisplayIOSurfaceRenderable` per device. Four cases the
/// picker has to handle:
///
///   - Conformance can be carried by either the port or its
///     `port.descriptor`; enumerate both.
///   - Conformance can be claimed via the protocol *or* by responding to
///     either callback selector shape; check both.
///   - Prefer candidates with non-zero `displaySize`. If none has a size
///     (shouldn't happen on a booted device, but defensive), fall back to
///     the first conformer.
///   - When several have a size, sample their content to choose a panel;
///     otherwise fall back to enumeration order.
- (nullable id<SimDisplayIOSurfaceRenderable>)_findRenderableWithError:(NSError **)error {
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

    // Prefer a renderable with non-zero displaySize, which is the one
    // actually bound to a screen. Fall back to the first conformer if
    // none has a size yet (early boot transient).
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
    // Selection is not revisited while the subscription runs, so a wrong
    // answer here costs a blank pane until it is stopped and started again.
    // Worth a bounded wait to avoid.
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
    //
    // **This selection does not self-correct.** Callbacks are registered
    // against the chosen renderable only, so a panel that lights up later
    // goes unnoticed. Recovering needs a consumer that watches every
    // candidate, which does not exist yet; until it does, a pane that lands
    // here stays on this panel until the subscription is stopped and
    // started again.
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

#pragma mark Start / stop

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

    __weak SimDisplayHandle *weakSelf = self;

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
        CSBDisplaySurfaceCallback cb = strong.callback;
        if (cb && ref) cb(ref);
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
        CSBDisplaySurfaceCallback cb = strong.callback;
        if (cb) cb(ref);
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
    if (!registered) {
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
        self.orientationCallback = nil;
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

- (void)stopOrientation {
    self.orientationCallback = nil;
    NSUUID *uuid = self.screenCallbackUUID;
    if (!uuid) return;
    self.screenCallbackUUID = nil;
    id<CSBSimScreen> screen = [self _screen];
    @try {
        [screen unregisterScreenCallbacksWithUUID:uuid];
    } @catch (NSException *e) {}
}

#pragma mark Stop

- (void)stop {
    self.callback = nil;
    [self stopOrientation];
    if (!self.running) return;
    self.running = NO;
    id<SimDisplayIOSurfaceRenderable> renderable = self.renderable;
    if ([renderable respondsToSelector:@selector(unregisterIOSurfacesChangeCallbackWithUUID:)]) {
        [renderable unregisterIOSurfacesChangeCallbackWithUUID:self.callbackUUID];
    }
    if ([renderable respondsToSelector:@selector(unregisterIOSurfaceChangeCallbackWithUUID:)]) {
        [renderable unregisterIOSurfaceChangeCallbackWithUUID:self.callbackUUID];
    }
    // The damage callback was registered alongside the IOSurface ones,
    // so unregister it too. Repeated start/stop cycles otherwise leak block
    // registrations into CoreSimulator that live until the proxy goes
    // away.
    id renderableUntyped = renderable;
    if ([renderableUntyped respondsToSelector:@selector(unregisterDamageRectanglesCallbackWithUUID:)]) {
        [renderableUntyped unregisterDamageRectanglesCallbackWithUUID:self.callbackUUID];
    }
    self.renderable = nil;
}

@end
