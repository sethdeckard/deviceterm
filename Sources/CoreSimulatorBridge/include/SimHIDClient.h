// SPDX-License-Identifier: GPL-3.0-or-later
//
// SimHIDClient: Indigo-wire-format HID injection into a booted
// simulator.
//
// Two transports. SimulatorKit's `SimDeviceLegacyHIDClient` (Swift-bridged
// class) carries Indigo binary messages; the simulator's HID daemon
// (`dtuhidd`, the one Device Hub drives) carries the messages a
// `CSBRemoteHIDMessageBuilding` builds. When the daemon is reachable,
// touches (single-finger, two-finger, and edge, on any panel), keyboard
// keys, and the hardware buttons it has events for go to it, because the
// simulator disconnects the services Indigo feeds whenever that daemon is
// active. The Digital Crown, whose service the simulator leaves connected,
// and buttons the daemon has no event for stay on Indigo. The Indigo
// wire-format details
// (doubled touch payloads, two-finger byte offsets, the 0x32 mouse target
// magic, the hardware-button source constants) were established by
// reverse engineering against a live simulator and are preserved
// verbatim. Don't rewrite them from first principles.
//
// Coordinates: every touch input is in **normalized** simulator-display
// space: (0, 0) is top-left, (1, 1) is bottom-right. The bridge does
// not know the display's pixel size; the caller computes the ratio.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "SimHIDSendLedger.h"
#import "SimRemoteHIDMessages.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CSBHardwareButton) {
    CSBHardwareButtonHome,
    CSBHardwareButtonLock,
    CSBHardwareButtonSideButton,
    CSBHardwareButtonApplePay,
    CSBHardwareButtonSiri,
    CSBHardwareButtonDigitalCrown,
};

/// HID injection client for one booted simulator.
///
/// **Not `Sendable` by design.** Holds a `SimDeviceLegacyHIDClient`
/// instance and a serial dispatch queue used to serialize sends.
/// Acquire transiently inside the daemon's `DeviceCoordinator` actor
/// and drop after use; for long-lived references keep the UDID and
/// reacquire.
@interface SimHIDClient : NSObject

/// Acquire a HID client for a booted device. Lazy-loads SimulatorKit
/// (the bridge's `CoreSimulatorLoader.loadSimulatorKit()` is called
/// internally, and is idempotent across clients).
+ (nullable instancetype)clientForUDID:(NSString *)udid
                                 error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(client(forUDID:));

/// Acquire a HID client that sends through the simulator's HID daemon where
/// `remoteMessages` has messages for it. Opens and anchors the daemon's touch
/// connection before returning, which takes about half a second; a daemon
/// that can't be reached leaves the client on Indigo alone, with
/// `remoteHIDUnavailableReason` saying why.
+ (nullable instancetype)clientForUDID:(NSString *)udid
                        remoteMessages:(nullable id<CSBRemoteHIDMessageBuilding>)remoteMessages
                                 error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(client(forUDID:remoteMessages:));

/// Whether this client sends through the simulator's HID daemon. Once it
/// does, keys and the buttons the daemon has events for go only there, and
/// fail rather than fall back to Indigo when their connection won't open.
@property (atomic, readonly) BOOL sendsThroughRemoteHID;

/// Why there's no remote touch channel, when `sendsThroughRemoteHID` is
/// false.
@property (atomic, readonly, copy, nullable) NSString *remoteHIDUnavailableReason;

/// Try the daemon again when this client was given messages for it but
/// couldn't reach it, at most once every five seconds. A simulator attached
/// while booting may not have the daemon's services up yet. Call only with
/// nothing held down, since a success moves later input to the daemon and a
/// contact sent through Indigo would be left there.
- (void)retryRemoteHIDIfDue;

@property (nonatomic, copy, readonly) NSString *udid;

/// The panel touch contacts are addressed to, as its `screenID`, or `0` for
/// Indigo's fixed digitizer target.
///
/// A device with two panels needs this. Its fixed digitizer target reaches
/// only one of them, and which one varies from boot to boot, so a contact
/// sent there can miss the panel that is lit. A non-zero value addresses the
/// contact to `screenID | 0x40000000`, the screen-based target, which reaches
/// the named panel. Touches sent through the simulator's HID daemon go to
/// that panel's touchscreen instead. Keys, buttons and the crown address no
/// panel and ignore it.
@property (atomic, assign) unsigned int touchScreenID;

/// The display UUID of the panel `touchScreenID` names, or nil when it is
/// unknown. Touches sent through the simulator's HID daemon go to the
/// touchscreen the daemon lists for this display, and fall back to the one
/// `touchScreenID` names when the daemon lists none for it.
@property (atomic, copy, nullable) NSString *touchScreenUniqueID;

// MARK: Send completion
//
// Every send below waits up to one second for its transport's completion
// (SimulatorKit's, or the message leaving this process for the HID daemon)
// and fails with `CSBHIDClientErrorSendTimeout` past that. The send is not
// cancelled: both transports send in order with no timeout of their own, so
// it may still complete, and delivery is unknown. A daemon connection that
// was lost and can't be replaced, or that hasn't opened (a later send tries
// again once five seconds have passed since the last attempt), fails the send
// with `CSBHIDClientErrorRemoteUnavailable`. While one is outstanding, every
// send that isn't a release fails with `CSBHIDClientErrorTransportStalled`
// without being sent. Releases (`tapUp`, `edgeTouchUp`, `twoFingerUp`,
// `keyUp`, `releaseHardwareButton`, and the up half of a press) still go out.

/// Sends handed to a transport whose completion hasn't arrived yet,
/// including ones whose wait has already timed out.
@property (nonatomic, readonly) NSUInteger outstandingSendCount;

/// Call `completionHandler` on this client's send queue once no send is
/// outstanding. Reports the first unreported error a send returned after its
/// wait had timed out, or nil if none remains. Reporting consumes the error;
/// handlers waiting together receive the same result. Waits with no deadline:
/// if the guest never takes its input, this never fires.
- (void)whenSendsSettleWithCompletionHandler:(void (^)(NSError * _Nullable error))completionHandler
    NS_SWIFT_NAME(whenSendsSettle(completionHandler:));

/// Call `handler` on this client's send queue once no send is outstanding.
/// Reports no error and consumes none, for a caller that only needs to know
/// the sends drained.
- (void)whenSendsDrainWithHandler:(void (^)(void))handler
    NS_SWIFT_NAME(whenSendsDrain(handler:));

// MARK: Single-finger touch
//
// A press-and-hold is `tapDown` + nothing else; the touch stays down
// until `tapUp`. A drag is `tapDown` + multiple `tapDown` calls at
// intermediate positions + `tapUp` at the final position. The
// digitizer interprets successive doubled-payload "down" messages at
// new positions as continued contact.

- (BOOL)tapDownAtNormalizedPoint:(CGPoint)point
                           error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(tapDown(at:));

- (BOOL)tapUpAtNormalizedPoint:(CGPoint)point
                         error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(tapUp(at:));

// MARK: Edge-tagged touch (system gestures: home indicator / App Switcher)
//
// A normal touch is `edge: none` and goes to app content. Tagging a
// touch with the screen edge it originates from (`edge` → the touch's
// `IndigoHIDEdge` slot) is what makes iOS route the drag to SpringBoard's
// system edge-gesture recognizer (home indicator / App Switcher / Control
// Center) instead of the foreground app. `edge` is the raw `IndigoHIDEdge`
// value. Contact continues across moves the same way a plain drag does, by
// re-sending the down at each new point; the Indigo builder offers no
// motion event type.

- (BOOL)edgeTouchDownAtNormalizedPoint:(CGPoint)point
                                  edge:(NSInteger)edge
                                 error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(edgeTouchDown(at:edge:));

- (BOOL)edgeTouchMoveAtNormalizedPoint:(CGPoint)point
                                  edge:(NSInteger)edge
                                 error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(edgeTouchMove(at:edge:));

- (BOOL)edgeTouchUpAtNormalizedPoint:(CGPoint)point
                                edge:(NSInteger)edge
                               error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(edgeTouchUp(at:edge:));

/// Whether this host's SimulatorKit still builds an edge-tagged message for
/// every phase the system-gesture path sends, with the tag reaching the
/// touch payload.
///
/// `dlsym` proves the symbol's name, not what it accepts. The symbol may
/// resolve even when invoking the builder for a required event type
/// returns NULL. A dropped `IndigoHIDEdge` is quieter still, since the
/// message builds and sends and the gesture reaches the foreground app
/// rather than SpringBoard, so each phase is built both tagged and
/// untagged and the two compared. Loads SimulatorKit if needed; needs no
/// device and no booted simulator.
+ (BOOL)isEdgeTouchBuildableWithError:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(isEdgeTouchBuildable());

// MARK: Two-finger touch (pinch / rotate / two-finger pan)
//
// Same successive-down semantics as single-finger.

- (BOOL)twoFingerDownAtFinger1:(CGPoint)f1
                       finger2:(CGPoint)f2
                         error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(twoFingerDown(f1:f2:));

- (BOOL)twoFingerUpAtFinger1:(CGPoint)f1
                     finger2:(CGPoint)f2
                       error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(twoFingerUp(f1:f2:));

// MARK: Keyboard
//
// **Keycodes here are USB HID usage codes**, not macOS HIToolbox
// virtual key codes (kVK_*). Indigo's `IndigoHIDMessageForKeyboard
// Arbitrary` sends the value to the simulator as-is, and the
// simulator interprets it as HID. The two number spaces don't
// overlap (e.g. 'a' is kVK 0x00 but HID 0x04), so feeding a
// virtual key code here silently produces gibberish.
//
// The daemon's input layer owns the `kVK → HID usage` translation
// (see `KeyboardInputMap.kVKToHIDUsage`). Callers who already have
// HID codes, i.e. they translated upstream, pass them through
// directly.
//
// Through the simulator's HID daemon, keys go to the daemon's own
// keyboard rather than a registered one. The simulator counts a
// registered keyboard as attached hardware and hides its on-screen
// keyboard for as long as it stays registered; the daemon's own
// keyboard leaves the on-screen keyboard available.

- (BOOL)keyDownWithKeyCode:(unsigned int)keyCode
                     error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(keyDown(keyCode:));

- (BOOL)keyUpWithKeyCode:(unsigned int)keyCode
                   error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(keyUp(keyCode:));

// MARK: Hardware buttons
//
// Down → 50ms gap → up. Synchronous; returns once both events are
// acknowledged. Callers wanting finer control over button-hold timing
// should drive the underlying message builders themselves.

- (BOOL)pressHardwareButton:(CSBHardwareButton)button
                      error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(pressHardwareButton(_:));

// Release-only (button up, no preceding down). Neutralizes a button whose
// press+release composite may have left it stuck down. Used by the input
// transfer quiesce, which must never replay a full press (that could fire a
// fresh action). Up phase only: the `fnButton` symbol for ordinary buttons,
// or the `fnHIDArbitrary` voice-command usage (up) for Siri, mirroring how
// `pressHardwareButton` routes each.
- (BOOL)releaseHardwareButton:(CSBHardwareButton)button
                        error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(releaseHardwareButton(_:));

// MARK: Digital Crown (watchOS)
//
// Analog rotary input. `delta` is a signed rotation magnitude: the sign
// is the direction, the magnitude is how far. Sent as a single Indigo
// "digital crown" event (SimulatorKit's `IndigoHIDMessageForDigitalCrown
// Event`). The magnitude's unit is calibrated empirically by the
// daemon/CLI layer; the bridge passes it straight through.

- (BOOL)rotateCrownByDelta:(double)delta
                     error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(rotateCrown(delta:));

/// Whether this host's SimulatorKit exports the Digital Crown builder.
/// The crown is watchOS-only and optional (absent on older Xcode), so
/// callers can gate crown features on this instead of catching the
/// "unavailable" error from `rotateCrown(delta:)`. Loads SimulatorKit if
/// needed; returns NO if it can't be loaded or the symbol is missing.
+ (BOOL)isDigitalCrownAvailable
    NS_SWIFT_NAME(isDigitalCrownAvailable());

@end

NS_ASSUME_NONNULL_END
