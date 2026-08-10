// SPDX-License-Identifier: GPL-3.0-or-later
//
// SimDeviceHandle: wrapper around CoreSimulator's private `SimDevice`.
//
// Exposes Swift-friendly types for device enumeration, lifecycle (boot /
// shutdown), and identity queries. Subsequent bridge modules
// (SimDisplayHandle, SimHIDClient, etc.) acquire their device-scoped
// state through this handle's UDID.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// CoreSimulator's `SimDeviceState` raw-value enum, mirrored 1:1.
///
/// Empirically confirmed on macOS 26.4 / Xcode 26.4 and aligned with
/// FBSimulatorControl's `FBSimulatorState`. Any raw value outside this
/// inventory normalizes to `CSBSimStateUnknown` and is never silently
/// mapped onto a real state.
typedef NS_ENUM(NSInteger, CSBSimState) {
    CSBSimStateUnknown      = -1,
    CSBSimStateCreating     = 0,
    CSBSimStateShutdown     = 1,
    CSBSimStateBooting      = 2,
    CSBSimStateBooted       = 3,
    CSBSimStateShuttingDown = 4,
};

/// Immutable snapshot of a `SimDevice`. Safe to copy across actor
/// boundaries because every property is an immutable string or enum value.
NS_SWIFT_SENDABLE
@interface CSBDeviceInfo : NSObject
@property (nonatomic, copy, readonly) NSString *udid;
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSString *runtimeIdentifier;
@property (nonatomic, copy, readonly) NSString *deviceTypeIdentifier;
/// Human-readable device type name from `SimDeviceType.name`, e.g.
/// "Apple Watch Ultra 3 (49mm)" or "iPhone 17 Pro". Empty string
/// when the deviceType isn't available (rare; happens if Apple
/// removes the property). Used by the GUI to render
/// "Name · Type" in the pane chrome.
@property (nonatomic, copy, readonly) NSString *deviceTypeName;
@property (nonatomic, readonly) CSBSimState state;
@end


/// Live handle onto a single `SimDevice`.
///
/// **Not `Sendable` by design.** Instance methods reach through a mutable
/// `SimDevice *` without internal serialization, so the compiler must
/// stop callers from moving the same handle across actors or tasks.
///
/// Use a handle as a **transient lookup result** within a serializing
/// context (the daemon's `DeviceCoordinator` actor):
///
/// ```swift
/// // In DeviceCoordinator actor
/// func reboot(_ udid: String) async throws {
///     let handle = try SimDeviceHandle.handle(forUDID: udid)
///     try handle.shutdown()
///     try handle.boot()
///     // handle drops out of scope; never escapes the actor.
/// }
/// ```
///
/// For long-lived references, store the `udid` string or a
/// `CSBDeviceInfo` snapshot, both of which are `Sendable`, and
/// reacquire the handle each time you need to act on the device.
@interface SimDeviceHandle : NSObject

/// Snapshot every device in the default device set, regardless of state.
+ (nullable NSArray<CSBDeviceInfo *> *)allDevicesWithError:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(allDevices());

/// Return the unique currently-booted device. Returns nil + error if zero
/// or more than one are booted (caller must disambiguate).
+ (nullable CSBDeviceInfo *)singleBootedDeviceWithError:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(singleBootedDevice());

/// Acquire a handle for the device with this UDID. Returns nil + error
/// if the UDID isn't present in the default device set. UDID match is
/// case-insensitive.
+ (nullable instancetype)handleForUDID:(NSString *)udid
                                 error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(handle(forUDID:));

@property (nonatomic, copy, readonly) NSString *udid;
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSString *runtimeIdentifier;
@property (nonatomic, copy, readonly) NSString *deviceTypeIdentifier;
/// See `CSBDeviceInfo.deviceTypeName`. Live read from
/// `SimDeviceType.name`.
@property (nonatomic, copy, readonly) NSString *deviceTypeName;

/// Live state read that re-fetches from `SimDevice.state` on each call.
@property (nonatomic, readonly) CSBSimState state;

/// Boot the device. Returns when CoreSimulator has accepted the boot
/// *intent*, not when SpringBoard has rendered. Callers waiting for a
/// renderable surface should subscribe to `SimDisplayHandle` events.
- (BOOL)bootWithError:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(boot());

/// Shut down the device. Returns when CoreSimulator reports the device
/// as `Shutdown` (synchronous).
- (BOOL)shutdownWithError:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(shutdown());

@end

NS_ASSUME_NONNULL_END
