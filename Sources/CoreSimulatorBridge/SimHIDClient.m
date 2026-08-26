// SPDX-License-Identifier: GPL-3.0-or-later

#import "SimHIDClient.h"
#import "CoreSimulatorLoader.h"

#import <CoreSimulator/SimServiceContext.h>
#import <CoreSimulator/SimDeviceSet.h>
#import <CoreSimulator/SimDevice.h>
#import <SimulatorKit/SimDeviceLegacyClient.h>
#import <SimulatorApp/Indigo.h>

#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach/mach_time.h>

static NSString *const kCSBErrorDomain = @"CoreSimulatorBridge.SimHIDClient";

typedef NS_ENUM(NSInteger, CSBHIDClientError) {
    CSBHIDClientErrorCoreSimLoad     = 40,
    CSBHIDClientErrorSimKitLoad      = 41,
    CSBHIDClientErrorContext         = 42,
    CSBHIDClientErrorDeviceSet       = 43,
    CSBHIDClientErrorDeviceNotFound  = 44,
    CSBHIDClientErrorLegacyClassMissing = 45,
    CSBHIDClientErrorLegacyInitFailed   = 46,
    CSBHIDClientErrorIndigoSymsMissing  = 47,
    CSBHIDClientErrorNilMessage      = 48,
    CSBHIDClientErrorSendTimeout     = 49,
};

// SimulatorKit-private Indigo helper signatures. The bridge calls these
// via dlsym so we can fail-fast with a clear error if Apple renames or
// removes them.
typedef IndigoMessage *(*CSBIndigoMessageForButtonFn)(int eventSource, int op, int target);
typedef IndigoMessage *(*CSBIndigoMessageForKeyboardFn)(int keyCode, int op);
typedef IndigoMessage *(*CSBIndigoMessageForMouseFn)(CGPoint *point0, CGPoint *point1, int target, int eventType, BOOL flag);
// The SAME symbol (`IndigoHIDMessageForMouseNSEvent`), but bound with its
// true 6-arg prototype (the framework's embedded string is
// `IndigoHIDMessageForMouseNSEvent(CGPoint*, CGPoint*, IndigoHIDTarget,
// NSEventType, NSSize, IndigoHIDEdge)`). The legacy `…MouseFn` typedef
// above is short by two args: it omits `NSSize` and `IndigoHIDEdge`, so
// the plain-touch path has always passed `edge = 0` (the `BOOL flag` it
// sends lands in the edge integer register) with a garbage `NSSize` in
// the FP registers. That's harmless for taps/drags, which overwrite the ratio
// fields afterward. We keep that call site byte-identical (proven) and
// use THIS pointer only for edge-tagged system gestures, where the
// `IndigoHIDEdge` arg is load-bearing and a `MouseDragged` build with a
// garbage `NSSize` returns NULL / crashes the sim. On arm64 the `NSSize`
// (two doubles) is passed in v0/v1, so `edge` is the 5th *integer* arg.
typedef IndigoMessage *(*CSBIndigoMessageForMouseEdgeFn)(CGPoint *point0, CGPoint *point1, NSInteger target, NSUInteger eventType, CGSize size, NSInteger edge);
// IndigoHIDMessageForHIDArbitrary(target, usagePage, usage, op) sends an
// arbitrary HID usage. Arg→field mapping reverse-engineered by comparing its
// disassembly to IndigoHIDMessageForButton (target@0x38, op@0x34; the two
// remaining fields at 0x44/0x3c are usagePage/usage).
typedef IndigoMessage *(*CSBIndigoMessageForHIDArbitraryFn)(int target, int usagePage, int usage, int op);
// IndigoHIDMessageForDigitalCrownEvent(double delta) is the watchOS Digital
// Crown rotary event. A single `double` arg (the signed rotation delta): the
// builder stores it into the wheel payload at offset 0x3c with payload kind 6
// and the crown discriminator 0x34 at 0x4c (the sibling
// IndigoHIDMessageForDigitalDialEvent is byte-identical but writes 0xc8 there).
// Signature disassembly-confirmed against IndigoHIDMessageForButton.
typedef IndigoMessage *(*CSBIndigoMessageForDigitalCrownFn)(double delta);

@interface SimHIDClient ()
@property (nonatomic, copy, readwrite) NSString *udid;
@property (nonatomic, strong) SimDeviceLegacyClient *legacyClient;
@property (nonatomic, strong) dispatch_queue_t sendQueue;

// dlsym'd at construction. All are non-NULL after a successful
// `clientForUDID:` except `fnCrown`, which is optional (watchOS-only)
// and is checked at each use.
@property (nonatomic, assign) CSBIndigoMessageForButtonFn       fnButton;
@property (nonatomic, assign) CSBIndigoMessageForKeyboardFn     fnKeyboard;
@property (nonatomic, assign) CSBIndigoMessageForMouseFn        fnMouse;
@property (nonatomic, assign) CSBIndigoMessageForMouseEdgeFn    fnMouseEdge;
@property (nonatomic, assign) CSBIndigoMessageForHIDArbitraryFn fnHIDArbitrary;
@property (nonatomic, assign) CSBIndigoMessageForDigitalCrownFn fnCrown;
@end

@implementation SimHIDClient

#pragma mark Construction

+ (nullable SimDevice *)_lookupDeviceForUDID:(NSString *)udid error:(NSError **)error {
    Class ctxCls = NSClassFromString(@"SimServiceContext");
    if (!ctxCls) {
        if (error) {
            *error = [NSError errorWithDomain:kCSBErrorDomain code:CSBHIDClientErrorContext userInfo:@{
                NSLocalizedDescriptionKey: @"SimServiceContext class not found",
            }];
        }
        return nil;
    }
    NSString *devDir = [CoreSimulatorLoader resolveDeveloperDir];
    NSError *inner = nil;
    SimServiceContext *ctx = [ctxCls sharedServiceContextForDeveloperDir:devDir error:&inner];
    if (!ctx) {
        if (error) {
            *error = inner ?: [NSError errorWithDomain:kCSBErrorDomain
                                                  code:CSBHIDClientErrorContext userInfo:@{
                NSLocalizedDescriptionKey: @"sharedServiceContextForDeveloperDir failed",
            }];
        }
        return nil;
    }
    SimDeviceSet *set = [ctx defaultDeviceSetWithError:&inner];
    if (!set) {
        if (error) {
            *error = inner ?: [NSError errorWithDomain:kCSBErrorDomain
                                                  code:CSBHIDClientErrorDeviceSet userInfo:@{
                NSLocalizedDescriptionKey: @"defaultDeviceSetWithError returned nil",
            }];
        }
        return nil;
    }
    NSString *needle = udid.lowercaseString;
    for (SimDevice *dev in set.devices) {
        if ([dev.UDID.UUIDString.lowercaseString isEqualToString:needle]) {
            return dev;
        }
    }
    if (error) {
        *error = [NSError errorWithDomain:kCSBErrorDomain
                                     code:CSBHIDClientErrorDeviceNotFound
                                 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Device with UDID %@ not found", udid],
        }];
    }
    return nil;
}

+ (nullable instancetype)clientForUDID:(NSString *)udid error:(NSError **)error {
    if (![CoreSimulatorLoader loadWithError:error]) return nil;
    if (![CoreSimulatorLoader loadSimulatorKitWithError:error]) return nil;

    SimDevice *device = [self _lookupDeviceForUDID:udid error:error];
    if (!device) return nil;

    // The instantiated class is the Swift-bridged subclass; its parent
    // SimDeviceLegacyClient exists only as a static-typing aid in the
    // vendored headers.
    Class legacyHIDClass = NSClassFromString(@"SimulatorKit.SimDeviceLegacyHIDClient");
    if (!legacyHIDClass) {
        if (error) {
            *error = [NSError errorWithDomain:kCSBErrorDomain
                                         code:CSBHIDClientErrorLegacyClassMissing
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"SimulatorKit.SimDeviceLegacyHIDClient not found",
            }];
        }
        return nil;
    }

    NSError *inner = nil;
    SimDeviceLegacyClient *legacy = [[legacyHIDClass alloc] initWithDevice:device error:&inner];
    if (!legacy) {
        if (error) {
            *error = inner ?: [NSError errorWithDomain:kCSBErrorDomain
                                                  code:CSBHIDClientErrorLegacyInitFailed
                                              userInfo:@{
                NSLocalizedDescriptionKey: @"SimDeviceLegacyHIDClient init failed",
            }];
        }
        return nil;
    }

    // Indigo helpers live in SimulatorKit; dlsym after its load.
    CSBIndigoMessageForButtonFn   fnButton   = (CSBIndigoMessageForButtonFn)
        dlsym(RTLD_DEFAULT, "IndigoHIDMessageForButton");
    CSBIndigoMessageForKeyboardFn fnKeyboard = (CSBIndigoMessageForKeyboardFn)
        dlsym(RTLD_DEFAULT, "IndigoHIDMessageForKeyboardArbitrary");
    CSBIndigoMessageForMouseFn    fnMouse    = (CSBIndigoMessageForMouseFn)
        dlsym(RTLD_DEFAULT, "IndigoHIDMessageForMouseNSEvent");
    // Same symbol, true 6-arg prototype, used only by the edge-tagged
    // system-gesture path. Resolving the same address twice with two
    // typedefs is intentional (the call signature differs).
    CSBIndigoMessageForMouseEdgeFn fnMouseEdge = (CSBIndigoMessageForMouseEdgeFn)
        dlsym(RTLD_DEFAULT, "IndigoHIDMessageForMouseNSEvent");
    CSBIndigoMessageForHIDArbitraryFn fnHIDArbitrary = (CSBIndigoMessageForHIDArbitraryFn)
        dlsym(RTLD_DEFAULT, "IndigoHIDMessageForHIDArbitrary");
    // The Digital Crown builder is watchOS-only and absent on older
    // SimulatorKit installs. It is OPTIONAL: dlsym it, but its absence must
    // NOT fail client construction. Doing so would regress every iOS HID
    // path (touch / keyboard / Siri / hardware buttons) that doesn't use it.
    // Only `rotateCrownByDelta:` requires it (and errors clearly if nil).
    CSBIndigoMessageForDigitalCrownFn fnCrown = (CSBIndigoMessageForDigitalCrownFn)
        dlsym(RTLD_DEFAULT, "IndigoHIDMessageForDigitalCrownEvent");
    if (!fnButton || !fnKeyboard || !fnMouse || !fnHIDArbitrary) {
        if (error) {
            *error = [NSError errorWithDomain:kCSBErrorDomain
                                         code:CSBHIDClientErrorIndigoSymsMissing
                                     userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:
                    @"Indigo helper symbols missing (button=%p keyboard=%p mouse=%p hid=%p)",
                    fnButton, fnKeyboard, fnMouse, fnHIDArbitrary],
            }];
        }
        return nil;
    }

    SimHIDClient *client = [SimHIDClient new];
    client.udid = udid;
    client.legacyClient = legacy;
    client.fnButton = fnButton;
    client.fnKeyboard = fnKeyboard;
    client.fnMouse = fnMouse;
    client.fnMouseEdge = fnMouseEdge;
    client.fnHIDArbitrary = fnHIDArbitrary;
    client.fnCrown = fnCrown;
    client.sendQueue = dispatch_queue_create("deviceterm.hid.send", DISPATCH_QUEUE_SERIAL);
    return client;
}

#pragma mark Send helper

/// Send an Indigo message and wait for completion (1s timeout). Returns
/// NO + a timeout error if completion never fires. `freeWhenDone:YES`
/// hands ownership of the message buffer to SimulatorKit.
- (BOOL)_sendMessage:(IndigoMessage *)message error:(NSError **)error {
    if (!message) {
        if (error) {
            *error = [NSError errorWithDomain:kCSBErrorDomain
                                         code:CSBHIDClientErrorNilMessage
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"Indigo message builder returned NULL",
            }];
        }
        return NO;
    }
    __block NSError *cbError = nil;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    [self.legacyClient sendWithMessage:message
                          freeWhenDone:YES
                       completionQueue:self.sendQueue
                            completion:^(NSError *e) {
        cbError = e;
        dispatch_semaphore_signal(sema);
    }];
    long timedOut = dispatch_semaphore_wait(sema,
        dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC));
    if (timedOut != 0) {
        if (error) {
            *error = [NSError errorWithDomain:kCSBErrorDomain
                                         code:CSBHIDClientErrorSendTimeout
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"HID send did not complete within 1s",
            }];
        }
        return NO;
    }
    if (cbError) {
        if (error) *error = cbError;
        return NO;
    }
    return YES;
}

#pragma mark Disconnect recovery

/// True for the "device disconnected" failure SimDeviceLegacyHIDClient
/// reports when its Mach port to the sim's HID service has died
/// (HIDError.machPortInvalid, code 3). Matching domain+code is stable
/// across the localized message text and Xcode versions.
static BOOL CSBIsDeviceDisconnected(NSError *error) {
    return error != nil
        && [error.domain isEqualToString:@"SimulatorKit.SimDeviceLegacyHIDClient.HIDError"]
        && error.code == 3;
}

/// Re-establish the legacy HID client after a disconnect. The dlsym'd
/// Indigo helpers and loaded frameworks stay valid, so only the device
/// lookup and `initWithDevice:` are redone. A fresh client re-registers
/// the Mach port, restoring input for subsequent sends.
- (BOOL)_reconnectLegacyClientWithError:(NSError **)error {
    SimDevice *device = [SimHIDClient _lookupDeviceForUDID:self.udid error:error];
    if (!device) return NO;
    Class legacyHIDClass = NSClassFromString(@"SimulatorKit.SimDeviceLegacyHIDClient");
    if (!legacyHIDClass) {
        if (error) {
            *error = [NSError errorWithDomain:kCSBErrorDomain
                                         code:CSBHIDClientErrorLegacyClassMissing
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"SimulatorKit.SimDeviceLegacyHIDClient not found",
            }];
        }
        return NO;
    }
    NSError *inner = nil;
    SimDeviceLegacyClient *legacy = [[legacyHIDClass alloc] initWithDevice:device error:&inner];
    if (!legacy) {
        if (error) {
            *error = inner ?: [NSError errorWithDomain:kCSBErrorDomain
                                                  code:CSBHIDClientErrorLegacyInitFailed
                                              userInfo:@{
                NSLocalizedDescriptionKey: @"SimDeviceLegacyHIDClient reconnect failed",
            }];
        }
        return NO;
    }
    self.legacyClient = legacy;
    return YES;
}

/// True for the NULL-build failure `_sendMessage:` reports when the builder
/// handed it nothing. The message never reached the legacy client, so this
/// failure says nothing about the HID port.
static BOOL CSBIsNilMessage(NSError *error) {
    return error != nil
        && [error.domain isEqualToString:kCSBErrorDomain]
        && error.code == CSBHIDClientErrorNilMessage;
}

/// Build and send an Indigo message, recovering once from a dead HID port.
/// `builder` must return a freshly allocated message on each call, since
/// `_sendMessage:` takes ownership and frees it. On a "device
/// disconnected" failure, reconnect and rebuild (the first message is
/// already freed), then retry exactly once. Bounding the retry to one
/// keeps a genuinely wedged port from looping.
///
/// Only a disconnect reconnects; a send timeout or any other error is
/// reported as it stands. A NULL build additionally says in its error why
/// retrying it is pointless, rather than leaving the next caller to work
/// that out: every builder is a dlsym'd Indigo helper plus local
/// arithmetic, none of them reads `legacyClient`, and that client is the
/// only state a reconnect replaces, so rebuilding behind one returns the
/// same NULL.
///
/// A reconnect that itself fails reports its own error. Falling back to
/// the disconnect that prompted it would name a condition the reconnect
/// was the response to, and hide the reason the response didn't land.
- (BOOL)_sendBuiltMessage:(IndigoMessage *(NS_NOESCAPE ^)(void))builder
                    error:(NSError **)error {
    NSError *sendError = nil;
    if ([self _sendMessage:builder() error:&sendError]) return YES;
    if (CSBIsDeviceDisconnected(sendError)) {
        NSError *reconnectError = nil;
        if ([self _reconnectLegacyClientWithError:&reconnectError]) {
            return [self _sendMessage:builder() error:error];
        }
        if (error) *error = reconnectError ?: sendError;
        return NO;
    }
    if (CSBIsNilMessage(sendError)) {
        if (error) {
            *error = [NSError errorWithDomain:kCSBErrorDomain
                                         code:CSBHIDClientErrorNilMessage
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"Indigo message builder returned NULL; nothing was sent. "
                                            "Not retried: the builder reads no HID client state, so a "
                                            "reconnect and rebuild return the same NULL.",
            }];
        }
        return NO;
    }
    if (error) *error = sendError;
    return NO;
}

#pragma mark Single-finger touch (doubled-payload, reverse-engineered)

/// Build a doubled-payload IndigoTouch message for a normalized point.
/// Single-payload messages are silently ignored by
/// SimHIDVirtualServiceManager: the digitizer needs the second payload
/// for the touch to land. Mirrors `FBSimulatorIndigoHID.m`'s
/// `touchMessageWithPayload:` construction. The byte layout and the
/// `0x0000000b / 0x00000001 / 0x00000002` field constants are
/// reverse-engineered and must not be "simplified."
///
/// **On the stride.** The Indigo.h comment says `innerSize` is "always
/// 0xa0 (160)", which is the stride SimulatorKit's own
/// `IndigoHIDMessageForMouseNSEvent` uses when allocating the
/// 3-payload two-finger buffer (see the two-finger path below: the
/// fixed byte offsets 0x3C/0x44/0xDC/0xE4/0x17C/0x184 implicitly encode
/// a 0xa0 stride). The single-finger doubled path is *different*: it
/// uses `sizeof(IndigoPayload)` = 0x90 as the stride
/// and writes `innerSize = 0x90`, and the digitizer accepts it. The
/// digitizer treats `innerSize` as the authoritative stride; the
/// 0xa0 in the header reflects helper convention, not a wire-format
/// requirement. **Keep both strides as they are**: the test
/// `tapDownThenTapUpSucceeds` covers single-finger, and the
/// two-finger byte offsets are pinned to their reverse-engineered
/// values.
- (IndigoMessage *)_buildTouchMessageAtRatio:(CGPoint)ratio direction:(int)direction {
    // SimulatorKit gives us a single-payload base message we can copy the
    // touch struct out of. We pass `ratio` as if it were a point, since we'll
    // overwrite xRatio/yRatio anyway.
    CGPoint pt = ratio;
    IndigoMessage *base = self.fnMouse(&pt, NULL, 0x32, direction, NO);
    if (!base) return NULL;
    base->payload.event.touch.xRatio = ratio.x;
    base->payload.event.touch.yRatio = ratio.y;

    size_t messageSize = sizeof(IndigoMessage) + sizeof(IndigoPayload);
    IndigoMessage *out = calloc(1, messageSize);
    out->innerSize = sizeof(IndigoPayload);
    out->eventType = IndigoEventTypeTouch;
    out->payload.field1 = 0x0000000b;
    out->payload.timestamp = mach_absolute_time();
    memcpy(&(out->payload.event.button), &(base->payload.event.button), sizeof(IndigoTouch));
    free(base);

    // Duplicate the payload at the next stride; the digitizer interprets
    // (first, second) as the matched pair that constitutes a real touch.
    IndigoPayload *first = &(out->payload);
    char *secondPos = (char *)first + sizeof(IndigoPayload);
    memcpy(secondPos, first, sizeof(IndigoPayload));
    IndigoPayload *second = (IndigoPayload *)secondPos;
    second->event.touch.field1 = 0x00000001;
    second->event.touch.field2 = 0x00000002;

    return out;
}

- (BOOL)tapDownAtNormalizedPoint:(CGPoint)point error:(NSError **)error {
    return [self _sendBuiltMessage:^IndigoMessage *{
        return [self _buildTouchMessageAtRatio:point direction:ButtonEventTypeDown];
    } error:error];
}

- (BOOL)tapUpAtNormalizedPoint:(CGPoint)point error:(NSError **)error {
    return [self _sendBuiltMessage:^IndigoMessage *{
        return [self _buildTouchMessageAtRatio:point direction:ButtonEventTypeUp];
    } error:error];
}

#pragma mark Edge-tagged touch (system gestures: home / App Switcher)

/// Like `_buildTouchMessageAtRatio:direction:`, but built through the
/// true 6-arg `fnMouseEdge` so the touch carries (1) an originating
/// screen `edge` (`IndigoHIDEdge`, what routes it to SpringBoard's
/// system edge-gesture recognizer instead of app content) and (2) a real
/// motion phase via `eventType` (`NSEventTypeLeftMouseDragged` = 6 for
/// the drag samples), not a stream of "down"s. A correct `NSSize` (we
/// pass zero, since the ratio fields are overwritten below anyway) keeps
/// the `MouseDragged` build from returning NULL / crashing the sim, which
/// is what calling this symbol through the 5-arg `fnMouse` typedef does.
- (IndigoMessage *)_buildEdgeTouchMessageAtRatio:(CGPoint)ratio
                                       eventType:(int)eventType
                                            edge:(int)edge {
    CGPoint pt = ratio;
    IndigoMessage *base = self.fnMouseEdge(&pt, NULL, 0x32, (NSUInteger)eventType, CGSizeZero, (NSInteger)edge);
    if (!base) return NULL;
    base->payload.event.touch.xRatio = ratio.x;
    base->payload.event.touch.yRatio = ratio.y;

    size_t messageSize = sizeof(IndigoMessage) + sizeof(IndigoPayload);
    IndigoMessage *out = calloc(1, messageSize);
    out->innerSize = sizeof(IndigoPayload);
    out->eventType = IndigoEventTypeTouch;
    out->payload.field1 = 0x0000000b;
    out->payload.timestamp = mach_absolute_time();
    memcpy(&(out->payload.event.button), &(base->payload.event.button), sizeof(IndigoTouch));
    free(base);

    IndigoPayload *first = &(out->payload);
    char *secondPos = (char *)first + sizeof(IndigoPayload);
    memcpy(secondPos, first, sizeof(IndigoPayload));
    IndigoPayload *second = (IndigoPayload *)secondPos;
    second->event.touch.field1 = 0x00000001;
    second->event.touch.field2 = 0x00000002;

    return out;
}

- (BOOL)edgeTouchDownAtNormalizedPoint:(CGPoint)point edge:(NSInteger)edge error:(NSError **)error {
    return [self _sendBuiltMessage:^IndigoMessage *{
        return [self _buildEdgeTouchMessageAtRatio:point eventType:0x1 edge:(int)edge];
    } error:error];
}

- (BOOL)edgeTouchMoveAtNormalizedPoint:(CGPoint)point edge:(NSInteger)edge error:(NSError **)error {
    // NSEventTypeLeftMouseDragged = 6: a real drag phase, not a re-down.
    return [self _sendBuiltMessage:^IndigoMessage *{
        return [self _buildEdgeTouchMessageAtRatio:point eventType:0x6 edge:(int)edge];
    } error:error];
}

- (BOOL)edgeTouchUpAtNormalizedPoint:(CGPoint)point edge:(NSInteger)edge error:(NSError **)error {
    return [self _sendBuiltMessage:^IndigoMessage *{
        return [self _buildEdgeTouchMessageAtRatio:point eventType:0x2 edge:(int)edge];
    } error:error];
}

#pragma mark Two-finger touch (3-payload, reverse-engineered)

/// Build a 3-payload IndigoTouch for two-finger gestures.
/// `IndigoHIDMessageForMouseNSEvent` allocates the right-sized buffer
/// when called with a non-NULL second point; we then patch the
/// xRatio/yRatio fields at the byte offsets observed in
/// `FBSimulatorIndigoHID.m` (IndigoPayload stride = 0xa0). The summary
/// digitizer record at 0xDC/0xE4 mirrors finger 1.
- (IndigoMessage *)_buildTwoFingerTouchMessageAtRatio1:(CGPoint)ratio1
                                                ratio2:(CGPoint)ratio2
                                             direction:(int)direction {
    CGPoint r1 = ratio1;
    CGPoint r2 = ratio2;
    IndigoMessage *message = self.fnMouse(&r1, &r2, 0x32, direction, NO);
    if (!message) return NULL;

    char *bytes = (char *)message;
    // Finger 1
    memcpy(bytes + 0x3C,  &ratio1.x, sizeof(double));
    memcpy(bytes + 0x44,  &ratio1.y, sizeof(double));
    // Digitizer summary mirrors finger 1
    memcpy(bytes + 0xDC,  &ratio1.x, sizeof(double));
    memcpy(bytes + 0xE4,  &ratio1.y, sizeof(double));
    // Finger 2
    memcpy(bytes + 0x17C, &ratio2.x, sizeof(double));
    memcpy(bytes + 0x184, &ratio2.y, sizeof(double));

    return message;
}

- (BOOL)twoFingerDownAtFinger1:(CGPoint)f1 finger2:(CGPoint)f2 error:(NSError **)error {
    return [self _sendBuiltMessage:^IndigoMessage *{
        return [self _buildTwoFingerTouchMessageAtRatio1:f1
                                                  ratio2:f2
                                               direction:ButtonEventTypeDown];
    } error:error];
}

- (BOOL)twoFingerUpAtFinger1:(CGPoint)f1 finger2:(CGPoint)f2 error:(NSError **)error {
    return [self _sendBuiltMessage:^IndigoMessage *{
        return [self _buildTwoFingerTouchMessageAtRatio1:f1
                                                  ratio2:f2
                                               direction:ButtonEventTypeUp];
    } error:error];
}

#pragma mark Keyboard

- (BOOL)keyDownWithKeyCode:(unsigned int)keyCode error:(NSError **)error {
    return [self _sendBuiltMessage:^IndigoMessage *{
        return self.fnKeyboard((int)keyCode, ButtonEventTypeDown);
    } error:error];
}

- (BOOL)keyUpWithKeyCode:(unsigned int)keyCode error:(NSError **)error {
    return [self _sendBuiltMessage:^IndigoMessage *{
        return self.fnKeyboard((int)keyCode, ButtonEventTypeUp);
    } error:error];
}

#pragma mark Hardware buttons

// The Consumer "Voice Command" HID usage (page 0x0C, usage 0xCF) is how iOS,
// and Apple's own Simulator "Device > Siri", invoke Siri. Reverse-engineered
// from the guest's backboardd "VoiceCommand page:0xC usage:0xCF" event.
static const int kCSBConsumerUsagePage = 0x0C;
static const int kCSBVoiceCommandUsage = 0xCF;

+ (int)_indigoSourceForButton:(CSBHardwareButton)b {
    switch (b) {
        case CSBHardwareButtonHome:       return ButtonEventSourceHomeButton;
        case CSBHardwareButtonLock:       return ButtonEventSourceLock;
        case CSBHardwareButtonSideButton: return ButtonEventSourceSideButton;
        case CSBHardwareButtonApplePay:   return ButtonEventSourceApplePay;
        // Siri does NOT use an Indigo button source. pressHardwareButton
        // routes it through the Voice Command consumer usage instead. The
        // legacy ButtonEventSourceSiri (0x400002) is rejected by the iOS 26
        // simulator and *wedges* its HID service. This case is unreachable.
        case CSBHardwareButtonSiri:       return ButtonEventSourceHomeButton;
        // On watchOS the Digital Crown *press* is the Home-equivalent, so it
        // rides the Home button source. (The crown *rotation* is a separate
        // analog event, handled by rotateCrownByDelta:.) Confirmed live: a crown
        // press returns the watch to its app grid / clock face.
        case CSBHardwareButtonDigitalCrown: return ButtonEventSourceHomeButton;
    }
    return ButtonEventSourceHomeButton;
}

/// Invoke Siri exactly as iOS does: a Consumer "Voice Command" HID usage
/// (page 0x0C, usage 0xCF) sent as a down/up pair through the arbitrary-HID
/// builder with the hardware target. This is what Apple's own Simulator
/// "Device > Siri" emits, verified against the guest's backboardd
/// "VoiceCommand page:0xC usage:0xCF" event. The old ButtonEventSourceSiri
/// button source is rejected on iOS 26 and wedges the HID service, so it is
/// never used.
- (BOOL)_pressVoiceCommandWithError:(NSError **)error {
    BOOL ok = [self _sendBuiltMessage:^IndigoMessage *{
        return self.fnHIDArbitrary(ButtonEventTargetHardware, kCSBConsumerUsagePage,
                                   kCSBVoiceCommandUsage, ButtonEventTypeDown);
    } error:error];
    if (!ok) return NO;
    usleep(50000);  // 50ms between down and up, matching the other buttons.
    return [self _sendBuiltMessage:^IndigoMessage *{
        return self.fnHIDArbitrary(ButtonEventTargetHardware, kCSBConsumerUsagePage,
                                   kCSBVoiceCommandUsage, ButtonEventTypeUp);
    } error:error];
}

- (BOOL)pressHardwareButton:(CSBHardwareButton)button error:(NSError **)error {
    if (button == CSBHardwareButtonSiri) {
        return [self _pressVoiceCommandWithError:error];
    }
    int source = [SimHIDClient _indigoSourceForButton:button];
    BOOL ok = [self _sendBuiltMessage:^IndigoMessage *{
        return self.fnButton(source, ButtonEventTypeDown, ButtonEventTargetHardware);
    } error:error];
    if (!ok) return NO;
    usleep(50000);  // 50ms between down and up, matching idb's timing.
    return [self _sendBuiltMessage:^IndigoMessage *{
        return self.fnButton(source, ButtonEventTypeUp, ButtonEventTargetHardware);
    } error:error];
}

- (BOOL)releaseHardwareButton:(CSBHardwareButton)button error:(NSError **)error {
    // Up phase only; no preceding down. Safely neutralizes a button whose
    // press+release composite may have left it stuck down, without the risk
    // a full re-press carries (firing a fresh action if the original failed
    // before down landed).
    if (button == CSBHardwareButtonSiri) {
        return [self _sendBuiltMessage:^IndigoMessage *{
            return self.fnHIDArbitrary(ButtonEventTargetHardware, kCSBConsumerUsagePage,
                                       kCSBVoiceCommandUsage, ButtonEventTypeUp);
        } error:error];
    }
    int source = [SimHIDClient _indigoSourceForButton:button];
    return [self _sendBuiltMessage:^IndigoMessage *{
        return self.fnButton(source, ButtonEventTypeUp, ButtonEventTargetHardware);
    } error:error];
}

#pragma mark Digital Crown

/// Rotate the watchOS Digital Crown by a signed delta via SimulatorKit's
/// dedicated `IndigoHIDMessageForDigitalCrownEvent`. A single send (no
/// down/up pair, since the crown is a continuous rotary, not a button). Sign is
/// direction; magnitude is distance. Routed through `_sendBuiltMessage:` for
/// the same disconnect-recovery as every other send.
+ (BOOL)isDigitalCrownAvailable {
    if (![CoreSimulatorLoader loadSimulatorKitWithError:NULL]) return NO;
    return dlsym(RTLD_DEFAULT, "IndigoHIDMessageForDigitalCrownEvent") != NULL;
}

- (BOOL)rotateCrownByDelta:(double)delta error:(NSError **)error {
    if (!self.fnCrown) {
        if (error) {
            *error = [NSError errorWithDomain:kCSBErrorDomain
                                         code:CSBHIDClientErrorIndigoSymsMissing
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"IndigoHIDMessageForDigitalCrownEvent is "
                    @"unavailable on this host; the Digital Crown needs a SimulatorKit "
                    @"that exports it (watchOS-capable Xcode).",
            }];
        }
        return NO;
    }
    return [self _sendBuiltMessage:^IndigoMessage *{
        return self.fnCrown(delta);
    } error:error];
}

@end
