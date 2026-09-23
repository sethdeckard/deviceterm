// SPDX-License-Identifier: GPL-3.0-or-later
//
// SimDisplayHandle: IOSurface streaming from a booted simulator's display.
//
// The bridge subscribes to CoreSimulator's display renderable and delivers
// every new surface to a caller-supplied callback as a raw `IOSurfaceRef`.
// The caller is responsible for retain/use-count pairing for the lifetime
// of any reference it keeps; the bridge holds the source surface only long
// enough to invoke the callback. The daemon's `RetainedSurface` wrapper
// (`Sources/Daemon/Surface/RetainedSurface.swift`) is the canonical owner: it
// pairs `IOSurfaceIncrementUseCount`/`CFRetain` at construction with the
// matching decrement/release in `deinit`, then crosses actors + XPC
// marshalling boundaries safely.
//
// On the multi-renderable picker:
// CoreSimulator exposes multiple proxies that conform to
// `SimDisplayIOSurfaceRenderable` on a single device, and there is no
// documented way to ask which is live. Enumerate both ports and
// descriptors, checking protocol conformance and callback selectors;
// proxy implementations expose these differently. Keep the candidates
// with non-zero `displaySize`.
//
// A foldable (iPhone Duo) vends one display descriptor per panel, both
// sized, and powers one at a time. `displayClass`, `powerState` and
// `uiOrientation` read the same on both, so they cannot say which is lit;
// `screenID` and `uniqueId` identify a panel but not its state. Sampled
// content is the discriminator the picker uses when more than one
// candidate is sized, and it records which panel it selected.
//
// That tie-break is a heuristic, and nothing re-runs it on its own. The
// handle never polls: callbacks are registered against the chosen renderable
// only, so a panel that lights up later goes unnoticed until a caller asks.
// `rebindToLitPanel` is that ask, and a caller that wants a pane to follow a
// fold has to drive it.

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


/// What the display is currently *presenting*, which is not the device's
/// attitude. An orientation-locked app keeps a portrait display while the
/// device is turned to landscape, so these are two different values and
/// only this one describes the framebuffer.
///
/// Cases 1…4 match `CSBDeviceOrientation`, but this is a separate enum
/// because an observation can be absent and a command target cannot:
/// `Unknown` covers a display that vends no orientation source and a
/// source value with no pane meaning.
typedef NS_ENUM(NSInteger, CSBDisplayOrientation) {
    CSBDisplayOrientationUnknown            = 0,
    CSBDisplayOrientationPortrait           = 1,
    CSBDisplayOrientationPortraitUpsideDown = 2,
    CSBDisplayOrientationLandscapeLeft      = 3,
    CSBDisplayOrientationLandscapeRight     = 4,
};

/// Block delivering the display's current orientation after a
/// screen-properties notification. Runs on the queue supplied at
/// registration.
///
/// **Values repeat.** The notification covers every screen property, not
/// just rotation, and the bridge does not deduplicate. Changes may also
/// coalesce. The value is read at delivery time, so it always describes
/// the display's state now rather than a delta, and a consumer that
/// compares against its own previous value gets a correct result either
/// way.
typedef void (^CSBDisplayOrientationCallback)(CSBDisplayOrientation orientation);


/// Display handle for one simulator. Manages the picker + callback
/// registration + lifecycle on a single renderable proxy.
///
/// **Not `Sendable` by design.** Methods touch the renderable proxy and
/// the held `SimDevice *` without internal serialization; callers
/// serialize via the daemon's `DeviceCoordinator` actor. Registered
/// callbacks are the exception: they run outside that actor, so the
/// properties they read are atomic, and an in-flight delivery can
/// finish after `stop` returns. Acquire
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

/// Identity of the selected panel, captured whenever the renderable is
/// resolved: at initial selection, and again when `rebindToLitPanel` moves to
/// another panel or restores the previous one. On a single-display device
/// this names its only screen; on a foldable it says which panel is being
/// mirrored.
///
/// `boundScreenID` is the small integer `simctl io --display` accepts and is
/// `0` when the proxy vends no `SimScreenProperties`. `boundScreenUniqueId`
/// is stable for a panel across folds, and nil in the same case. Both are
/// best-effort: a proxy without properties still binds and streams.
@property (nonatomic, readonly) unsigned int boundScreenID;
@property (nonatomic, readonly, nullable) NSString *boundScreenUniqueId;

/// Whether the device vended more than one sized display candidate when the
/// renderable was resolved, which is what a foldable's two panels look like
/// from here. False before `start(callback:)` and on every single-display
/// device, where it lets a caller skip the fold-following machinery.
@property (nonatomic, readonly) BOOL hasMultiplePanels;

/// Re-resolve the lit panel and move the subscription onto it if it changed.
/// Returns YES only when the bound panel actually moved.
///
/// **Deliberately conservative.** It rebinds only when the bound panel
/// samples as black *and* exactly one other candidate samples as lit, so an
/// ambiguous reading leaves the binding alone. Sampling is the same content
/// heuristic the picker uses, with its same blind spot: a lit panel drawing
/// black reads as dark. Identity comes from `boundScreenUniqueId`, so a proxy
/// that vends no `SimScreenProperties` can never be told apart from its
/// siblings and always returns NO.
///
/// **A fold is not instantaneous and this is not a fold event.** The panels
/// swap over a few hundred milliseconds, and in between neither is lit, so a
/// single call right after a fold usually returns NO. A caller that wants to
/// follow a fold polls until this returns YES or it gives up.
///
/// On success the surface and (if observing) screen-callback registrations
/// move to the new renderable, and `boundScreenID` / `boundScreenUniqueId`
/// are re-read. If the new panel already holds a surface, the surface
/// callback fires synchronously with it, so the consumer isn't left on the
/// old panel's last frame; if it holds none yet, the next delivery is the
/// first. `displaySize` reports the new panel's dimensions from here on. A
/// delivery still in flight from the old panel is dropped rather than
/// forwarded, so it cannot put a dark frame back after the swap.
///
/// **Nothing half-moved.** If either registration fails on the new panel the
/// binding goes back to the old one and this returns NO. Moving without
/// screen callbacks would leave the handle unable to notice any later fold,
/// which is worse than a blank pane a repeat call can still fix. Re-applying
/// the old panel's registrations is best effort: those results are not
/// checked, so a rollback can leave the handle bound to a panel it is no
/// longer registered on.
///
/// **Also a repair.** Observation requested through
/// `startOrientation(callback:queue:)` stays requested even if a registration
/// later fails, and each call retries it on the bound panel before doing
/// anything else. That gives a caller who keeps asking a fresh attempt each
/// time rather than a guarantee, and it is what makes a YES mean observation
/// was in place when this returned.
///
/// Returns NO when the handle isn't started, when the device has one panel,
/// on any reading that isn't an unambiguous swap, and when the move could not
/// be completed.
- (BOOL)rebindToLitPanel;

/// Begin observing the display's presented orientation. Requires a prior
/// successful `start(callback:)`: both ride the same display proxy, which
/// the surface subscription is what resolves.
///
/// **Call this before reading `currentDisplayOrientation`.** Registration
/// happens first so a rotation landing between the two is delivered as a
/// callback rather than lost in the gap between a snapshot and a
/// subscription.
///
/// Fails when the display proxy vends no orientation source, which leaves
/// the caller with no way to observe rotations. That is a degraded but
/// workable state, not a reason to drop the pane: frames are unaffected.
- (BOOL)startOrientationWithCallback:(CSBDisplayOrientationCallback)callback
                               queue:(dispatch_queue_t)queue
                               error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(startOrientation(callback:queue:));

/// The orientation the display is presenting right now, or
/// `CSBDisplayOrientationUnknown` if the proxy vends no orientation
/// source or reports a value with no pane meaning.
///
/// A bounded one-shot read, safe to call before
/// `startOrientationWithCallback:queue:error:`, though seeding after
/// registering is what avoids the gap.
@property (nonatomic, readonly) CSBDisplayOrientation currentDisplayOrientation;

/// Stop observing orientation. Idempotent, and called by `stop`.
- (void)stopOrientation;

/// Stop the subscription. Idempotent. After `stop`, CoreSimulator
/// dispatches no new surface callbacks and another `start(callback:)`
/// reattaches. A delivery already in flight can still run to completion,
/// which is why the callback state is atomic. Also stops orientation
/// observation.
- (void)stop;

@end

NS_ASSUME_NONNULL_END
