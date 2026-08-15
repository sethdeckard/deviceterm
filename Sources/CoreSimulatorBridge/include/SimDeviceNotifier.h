// SPDX-License-Identifier: GPL-3.0-or-later
//
// SimDeviceNotifier: wrapper around CoreSimulator's set-level
// notification handler.
//
// Subscribes to `SimDeviceSet.registerNotificationHandlerOnQueue:
// handler:` so every device state change in the default set surfaces
// as a `CSBNotifierEvent`, regardless of who initiated it.
// Used by the daemon to fill the shim's argv-detection blind spots
// (xcodebuild, Simulator.app, absolute-path `xcrun`, FFI callers,
// pre-existing booted sims at daemon startup).
//
// Why set-level: one registration covers every device in the set,
// including ones created after the subscription was installed. The
// per-device `SimDevice.registerNotificationHandlerOnQueue:handler:`
// surface exists but would require subscribing per UDID and
// re-subscribing for new devices.

#import <Foundation/Foundation.h>
#import "SimDeviceHandle.h"

NS_ASSUME_NONNULL_BEGIN

/// Notification payload kinds the bridge translates from
/// CoreSimulator's untyped notification dictionary. State changes
/// are the load-bearing case; other notifications (device added /
/// removed / paired etc.) are reported as `.other` for visibility
/// in debug logging without committing to a typed surface for them
/// until a caller actually needs it.
typedef NS_ENUM(NSInteger, CSBNotifierEventKind) {
    /// A device's `state` transitioned. `udid` and `newState` are
    /// populated; `previousState` is `CSBSimStateUnknown` when
    /// CoreSimulator didn't include the prior value in the payload.
    CSBNotifierEventKindStateChanged = 0,
    /// Any notification we recognised as carrying a SimDevice but
    /// not as a state transition (added / removed / pair changes
    /// / etc.). `udid` is populated; states are `CSBSimStateUnknown`.
    CSBNotifierEventKindOther        = 1,
};

/// Sendable snapshot of one notification. Safe to ship across an
/// actor boundary into the daemon's `DeviceCoordinator`.
NS_SWIFT_SENDABLE
@interface CSBNotifierEvent : NSObject
@property (nonatomic, readonly) CSBNotifierEventKind kind;
/// Device the notification was about. Empty string when we couldn't
/// extract one (unrecognised dict shape, surfaced for logging but
/// not actionable). Lowercase, hyphenated UUID form to match the
/// rest of the bridge.
@property (nonatomic, copy, readonly) NSString *udid;
@property (nonatomic, readonly) CSBSimState newState;
@property (nonatomic, readonly) CSBSimState previousState;
/// Raw `notification_name`-style key from the dict, if present.
/// Empty string otherwise. Diagnostic only; callers shouldn't
/// dispatch on it.
@property (nonatomic, copy, readonly) NSString *rawName;
@end

/// Live handle on a registered set-level notification handler.
///
/// **Not `Sendable`**: instance methods reach the private framework
/// surface without internal serialisation. Hold one as a transient
/// property inside the daemon's `DeviceCoordinator` actor; never
/// pass the handle itself across actor boundaries.
///
/// Lifecycle:
///
/// ```swift
/// // In DeviceCoordinator
/// let notifier = try SimDeviceNotifier.defaultNotifier(
///     queue: notificationQueue
/// ) { [weak self] event in
///     // event is Sendable, so it's safe to dispatch into the actor.
///     Task { await self?.handle(notifierEvent: event) }
/// }
/// self.notifier = notifier
/// // ...later, on daemon shutdown:
/// notifier.cancel()
/// ```
///
/// `cancel` is idempotent; `dealloc` cancels automatically as a
/// belt-and-suspenders guard, but explicit cancel before drop is
/// preferred so unregistration happens at a known point rather than
/// whenever the handle happens to be deallocated.
@interface CSBDeviceNotifier : NSObject

/// Register a handler on the default device set. The handler block
/// runs on `queue` (caller-owned; must outlive the notifier).
+ (nullable instancetype)defaultNotifierOnQueue:(dispatch_queue_t)queue
                                        handler:(void (^)(CSBNotifierEvent *event))handler
                                          error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(defaultNotifier(queue:handler:));

/// Stop receiving further events. Safe to call multiple times. After the
/// first call, notifications CoreSimulator already has queued on `queue`
/// are dropped rather than delivered.
///
/// **Not a barrier.** Handlers already past the cancellation check run to
/// completion, so events can still reach the block after `cancel` returns,
/// and more than one of them when `queue` is concurrent. Consumers must
/// tolerate a late delivery rather than treat the return as proof that
/// nothing more will arrive.
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
