// SPDX-License-Identifier: GPL-3.0-or-later
//
// SimDisplayHandle: IOSurface streaming from a booted simulator's display.
//
// The bridge subscribes to CoreSimulator's display renderable and delivers
// every new surface to a caller-supplied callback as a raw `IOSurfaceRef`.
// The caller is responsible for retain/use-count pairing for the lifetime
// of any reference it keeps; the bridge holds the source surface only long
// enough to invoke the callback. The daemon's `RetainedSurface` wrapper
// (`Sources/Daemon/RetainedSurface.swift`) is the canonical owner: it pairs
// `IOSurfaceIncrementUseCount`/`CFRetain` at construction with the matching
// decrement/release in `deinit`, then crosses actors + XPC marshalling
// boundaries safely.
//
// On the multi-renderable picker:
// CoreSimulator exposes multiple proxies that conform to
// `SimDisplayIOSurfaceRenderable` on a single device, but only one is
// actually bound to a real display. The picker enumerates every
// candidate (including each port's `descriptor`) and prefers the one
// with non-zero `displaySize`. There is no documented way to ask
// CoreSimulator which proxy is live; this was found empirically, at
// the cost of a multi-day debugging session. Rewriting it from first
// principles risks repeating that.

#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>

NS_ASSUME_NONNULL_BEGIN

/// Block fired when CoreSimulator delivers a new IOSurface for this
/// display. `surface` is a **borrowed** `IOSurfaceRef`, alive for
/// the duration of the callback only. The block must
/// `CFRetain`/`IOSurfaceIncrementUseCount` if it intends to outlive
/// the callback (the daemon does so via `RetainedSurface`).
///
/// The parameter is nullable for future-proofing, but the bridge never
/// invokes the block with NULL: every delivery path checks for a bound
/// surface first and skips the callback when there isn't one.
///
/// The block fires on whatever queue CoreSimulator's display proxy
/// delivers from (not the main queue). Consumers that need a specific
/// isolation should dispatch / `Task { … }` from inside the block.
typedef void (^CSBDisplaySurfaceCallback)(IOSurfaceRef _Nullable surface);


/// Display handle for one simulator. Manages the picker + callback
/// registration + lifecycle on a single renderable proxy.
///
/// **Not `Sendable` by design.** Methods touch the renderable proxy and
/// the held `SimDevice *` without internal serialization; callers
/// serialize via the daemon's `DeviceCoordinator` actor. Acquire
/// transiently: handle, subscribe, hold a `Task` on the surface stream,
/// drop the handle on stop. For long-lived references, keep the `udid`
/// string and reacquire.
@interface SimDisplayHandle : NSObject

/// Acquire a display handle for the device with this UDID. The device
/// must be in (or transitioning into) the `Booted` state. Otherwise
/// `device.io` is `nil` and `start(callback:)` will fail with a
/// "device not booted" error.
+ (nullable instancetype)handleForUDID:(NSString *)udid
                                 error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(handle(forUDID:));

@property (nonatomic, copy, readonly) NSString *udid;

/// Begin subscribing to surface changes. Calling `start` after a prior
/// `start` (without an intervening `stop`) replaces the callback; the
/// underlying CoreSimulator registration stays in place.
///
/// On a successful return:
/// - The callback has been registered with whichever of
///   `registerCallbackWithUUID:ioSurfaceChangeCallback:` and
///   `:ioSurfacesChangeCallback:` the proxy answers, and with at least
///   one of the two. Both are attempted because the proxy's
///   `respondsToSelector` answer doesn't always match which one
///   actually fires.
/// - A damage-rectangles callback is also registered. Without it, on
///   iOS 26.4 the underlying proxy never allocates its IOSurface.
/// - If a surface is already bound to the renderable, the block fires
///   synchronously before this returns so consumers don't have to wait
///   for the first frame callback.
- (BOOL)startWithCallback:(CSBDisplaySurfaceCallback)callback
                    error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(start(callback:));

/// Read the renderable's current surface. Returns NULL if no surface
/// is bound yet. Useful as a fallback for the rare stuck-state where
/// callbacks haven't fired but the proxy now has a surface.
///
/// **Ownership.** The returned ref is **+1 retained** (annotated
/// `CF_RETURNS_RETAINED`). The implementation pulls the underlying
/// surface object out of CoreSimulator (typically autoreleased) and
/// `CFRetain`s before returning so the caller can safely cross
/// actor / autorelease-pool boundaries. Swift callers receive the
/// retained value through CoreFoundation bridging (Swift's ARC
/// balances the +1 on scope exit). ObjC callers must `CFRelease`
/// when done. Without the retain, an autoreleased surface object
/// would dangle the moment the caller's scope drained its pool.
- (nullable IOSurfaceRef)currentSurface CF_RETURNS_RETAINED;

/// Best-effort display dimensions as reported by the chosen renderable
/// proxy, in pixels. Returns `CGSizeZero` if the proxy isn't bound to a
/// display yet (treat that as "ask again after the first callback").
@property (nonatomic, readonly) CGSize displaySize;

/// Stop the subscription. Idempotent. After `stop`, the callback is no
/// longer invoked; another `start(callback:)` reattaches.
- (void)stop;

@end

NS_ASSUME_NONNULL_END
