// SPDX-License-Identifier: GPL-3.0-or-later

#import <Foundation/Foundation.h>
#import <xpc/xpc.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Builds the messages a simulator's HID daemon takes. `SimHIDClient`
/// carries them to the daemon and never builds one itself, so the wire
/// vocabulary stays with the caller that owns it.
///
/// Message-building methods return fresh XPC objects, or nil where
/// documented. Points are in the client's
/// normalized display space; `edge` is the raw `IndigoHIDEdge` value the
/// client's edge-touch methods receive.
NS_SWIFT_SENDABLE
@protocol CSBRemoteHIDMessageBuilding <NSObject>

/// The daemon service that takes touch reports.
@property (nonatomic, readonly, copy) NSString *touchServiceName;

/// The daemon service that takes key events for its own keyboard.
@property (nonatomic, readonly, copy) NSString *keyboardServiceName;

/// The daemon service that takes hardware-button events.
@property (nonatomic, readonly, copy) NSString *buttonServiceName;

/// The first request on a touch connection. The daemon keeps a session only
/// once it has answered a request on it. This one asks for the session's
/// services.
- (xpc_object_t)sessionAnchor;

/// The touchscreen service id serving each display UUID, from the reply to
/// `sessionAnchor`.
- (NSDictionary<NSString *, NSNumber *> *)touchscreenServicesFromAnchorReply:(xpc_object_t)reply;

/// The touchscreen service id for screen `screenID` when the daemon's list
/// doesn't name the screen's display, or the main touchscreen for `0`.
- (uint64_t)touchscreenServiceIDForScreenID:(unsigned int)screenID;

/// One contact (`contact`) or release of a single finger, on touchscreen
/// service `serviceID`.
- (xpc_object_t)touchWithContact:(BOOL)contact x:(double)x y:(double)y serviceID:(uint64_t)serviceID;

/// Two fingers in one report, both in contact or both lifted, on
/// touchscreen service `serviceID`.
- (xpc_object_t)twoFingerTouchWithContact:(BOOL)contact
                                    first:(CGPoint)first
                                   second:(CGPoint)second
                                serviceID:(uint64_t)serviceID;

/// One contact or release of a system gesture from `edge`, on touchscreen
/// service `serviceID`.
- (xpc_object_t)gestureTouchWithContact:(BOOL)contact
                                      x:(double)x
                                      y:(double)y
                                   edge:(NSInteger)edge
                              serviceID:(uint64_t)serviceID;

/// One phase of the key with HID usage `usage` (keyboard page), for the
/// daemon's own keyboard.
- (xpc_object_t)keyboardEventForUsage:(unsigned int)usage down:(BOOL)down;

/// The request that registers a virtual keyboard on a touch connection. The
/// simulator counts it as attached hardware and hides its on-screen keyboard
/// until it's removed.
- (xpc_object_t)keyboardRegistration;

/// The service id the reply to `keyboardRegistration` confirms, or nil when
/// it confirms none.
- (nullable NSNumber *)keyboardServiceIDFromReply:(xpc_object_t)reply;

/// The report for the registered keyboard carrying every HID usage held down
/// now.
- (xpc_object_t)keyboardReportWithPressedUsages:(NSSet<NSNumber *> *)usages
                                      serviceID:(uint64_t)serviceID;

/// The request that removes the registered keyboard with `serviceID`.
- (xpc_object_t)keyboardRemovalForServiceID:(uint64_t)serviceID;

/// One phase of a hardware button, or nil for a button the vocabulary has
/// no event for. `button` is a `CSBHardwareButton`.
- (nullable xpc_object_t)buttonEventForButton:(NSInteger)button down:(BOOL)down;

/// How many presses one press of `button` takes: 2 for a button that is a
/// double press of another, 1 otherwise.
- (NSInteger)pressCountForButton:(NSInteger)button;

@end

NS_ASSUME_NONNULL_END
