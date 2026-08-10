// SPDX-License-Identifier: GPL-3.0-or-later
//
// SimPurpleHID: GSEvent over PurpleWorkspacePort.
//
// Indigo (the channel SimHIDClient uses) doesn't carry every input
// event the simulator understands. Device-orientation rotation in
// particular goes through a separate Mach-message channel that Apple's
// own Simulator.app uses: look up the `PurpleWorkspacePort` Mach
// service in the simulator's bootstrap namespace via
// `-[SimDevice lookup:error:]`, then `mach_msg_send` a 112-byte buffer
// shaped as a `mach_msg_header_t` + a GSEvent payload.
//
// The wire-format byte offsets, the `msgh_size = 108` constant, and
// the GSEvent type flag combination are reverse-engineered from
// Simulator.app's behavior and FBSimulatorControl's
// FBSimulatorPurpleHID; preserve them verbatim.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Device orientations supported by GSEvent. Raw values match
/// `UIDeviceOrientation` 1–4 so the simulator's layout engine reads
/// them directly. Names follow UIKit's convention exactly:
/// `LandscapeLeft = 3` (home button on the right) and
/// `LandscapeRight = 4` (home button on the left). Get this wrong and
/// `rotate(to: .landscapeLeft)` rotates the opposite direction, since
/// `rotateTo:` writes the raw enum value straight into the GSEvent
/// payload.
typedef NS_ENUM(NSInteger, CSBDeviceOrientation) {
    CSBDeviceOrientationPortrait            = 1,
    CSBDeviceOrientationPortraitUpsideDown  = 2,
    CSBDeviceOrientationLandscapeLeft       = 3,
    CSBDeviceOrientationLandscapeRight      = 4,
};

/// PurpleWorkspacePort HID client for one booted simulator.
///
/// **Not `Sendable` by design.** Holds a `SimDevice *` and looks up the
/// Mach port at every `rotateTo:` call (cheap; the port is cached
/// on the SimDevice side). Acquire transiently inside the daemon's
/// `DeviceCoordinator` actor.
@interface SimPurpleHID : NSObject

/// Acquire a Purple HID client for the device with this UDID.
+ (nullable instancetype)clientForUDID:(NSString *)udid
                                 error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(client(forUDID:));

@property (nonatomic, copy, readonly) NSString *udid;

/// Rotate the device to a specific orientation. Synchronous:
/// `mach_msg_send` returns once the message is queued on the
/// PurpleWorkspacePort. The simulator's relayout follows shortly
/// after; this method doesn't block on it.
- (BOOL)rotateTo:(CSBDeviceOrientation)orientation
           error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(rotate(to:));

@end

NS_ASSUME_NONNULL_END
