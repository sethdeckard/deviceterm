// SPDX-License-Identifier: GPL-3.0-or-later
//
// SimHIDClient: Indigo-wire-format HID injection into a booted
// simulator.
//
// Touches, two-finger gestures, keyboard keys, and hardware buttons all
// route through SimulatorKit's `SimDeviceLegacyHIDClient` (Swift-bridged
// class) as Indigo binary messages. The wire-format details (doubled
// touch payloads, two-finger byte offsets, the 0x32 mouse target
// magic, the hardware-button source constants) were established by
// reverse engineering against a live simulator and are preserved
// verbatim. Don't rewrite them from first principles.
//
// Coordinates: every touch input is in **normalized** simulator-display
// space: (0, 0) is top-left, (1, 1) is bottom-right. The bridge does
// not know the display's pixel size; the caller computes the ratio.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

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

@property (nonatomic, copy, readonly) NSString *udid;

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
