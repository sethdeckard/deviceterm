// SPDX-License-Identifier: GPL-3.0-or-later

#import "SimDisplayHandle.h"
#import "CoreSimulatorLoader.h"

#import <CoreSimulator/SimServiceContext.h>
#import <CoreSimulator/SimDeviceSet.h>
#import <CoreSimulator/SimDevice.h>
#import <CoreSimulator/SimDeviceIO.h>
#import <CoreSimulator/SimDeviceIOProtocol-Protocol.h>
#import <SimulatorKit/SimDisplayIOSurfaceRenderable-Protocol.h>
#import <SimulatorKit/SimDisplayRenderable-Protocol.h>

#import <objc/runtime.h>

static NSString *const kCSBErrorDomain = @"CoreSimulatorBridge.SimDisplayHandle";

typedef NS_ENUM(NSInteger, CSBDisplayHandleError) {
    CSBDisplayHandleErrorLoadFailed       = 20,
    CSBDisplayHandleErrorDeviceNotFound   = 21,
    CSBDisplayHandleErrorDeviceNotBooted  = 22,
    CSBDisplayHandleErrorNoIOPorts        = 23,
    CSBDisplayHandleErrorNoRenderable     = 24,
    CSBDisplayHandleErrorCallbackRegister = 25,
};

@interface SimDisplayHandle ()
@property (nonatomic, copy, readwrite) NSString *udid;
@property (nonatomic, strong, nullable) SimDevice *device;
@property (nonatomic, strong, nullable) NSUUID *callbackUUID;
@property (nonatomic, strong, nullable) id<SimDisplayIOSurfaceRenderable> renderable;
@property (nonatomic, copy, nullable) CSBDisplaySurfaceCallback callback;
@property (nonatomic, assign) BOOL running;
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
/// conform to `SimDisplayIOSurfaceRenderable` per device, but only one
/// is bound to a real display. Three cases the picker has to handle:
///
///   - Conformance can be carried by either the port or its
///     `port.descriptor`; enumerate both.
///   - Conformance can be claimed via the protocol *or* by responding to
///     either callback selector shape; check both.
///   - The "real" renderable is the one whose `displaySize` is non-zero;
///     prefer it. If none has a non-zero size (shouldn't happen on a
///     booted device, but defensive), fall back to the first conformer.
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
    id<SimDisplayIOSurfaceRenderable> chosen = nil;
    for (id<SimDisplayIOSurfaceRenderable> candidate in candidates) {
        CGSize size = CGSizeZero;
        @try {
            id untyped = candidate;
            if ([untyped respondsToSelector:@selector(displaySize)]) {
                size = [untyped displaySize];
            }
        } @catch (NSException *e) {}
        if (size.width > 0 && size.height > 0) {
            chosen = candidate;
            break;
        }
    }
    return chosen ?: candidates.firstObject;
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

- (void)stop {
    self.callback = nil;
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
