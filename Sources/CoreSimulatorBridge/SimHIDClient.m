// SPDX-License-Identifier: GPL-3.0-or-later

#import "SimHIDClient.h"
#import "SimHIDSendLedger.h"
#import "CoreSimulatorLoader.h"
#import "SimRemoteHIDChannel.h"
#import "SimRemoteHIDMessages.h"

#import <CoreSimulator/SimServiceContext.h>
#import <CoreSimulator/SimDeviceSet.h>
#import <CoreSimulator/SimDevice.h>
#import <SimulatorKit/SimDeviceLegacyClient.h>
#import <SimulatorApp/Indigo.h>

#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach/mach_time.h>

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
// the plain-touch path passes `edge = 0` (the `BOOL flag` it sends lands
// in the edge integer register) with a garbage `NSSize` in the FP
// registers. That's harmless: the builder reads `NSSize` only to scale the
// ratio fields, which both builders overwrite afterward. Use the full
// six-argument pointer only for edge-tagged gestures; plain touches retain
// the five-argument call. The edge argument routes system gestures to
// SpringBoard. On arm64 the `NSSize` (two doubles) is passed in v0/v1, so
// `edge` is the 5th *integer* arg.
//
// The builder accepts only the four down/up `NSEventType` values
// (`LeftMouseDown` 1, `LeftMouseUp` 2, and their right-button twins 3 and
// 4, which build byte-identical messages). Every motion type, including
// `MouseMoved` and `LeftMouseDragged`, returns NULL through either
// prototype, whatever `NSSize` and `IndigoHIDEdge` accompany it. So motion
// is expressed the way the digitizer already reads it, as a repeated down
// at a new point, not as a drag event.
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
/// Every send handed to SimulatorKit and not yet completed. Kept across a
/// reconnect, since a send on the old client can still complete.
@property (nonatomic, strong) SimHIDSendLedger *ledger;

// dlsym'd at construction. All are non-NULL after a successful
// `clientForUDID:` except `fnCrown`, which is optional (watchOS-only)
// and is checked at each use.
@property (nonatomic, assign) CSBIndigoMessageForButtonFn       fnButton;
@property (nonatomic, assign) CSBIndigoMessageForKeyboardFn     fnKeyboard;
@property (nonatomic, assign) CSBIndigoMessageForMouseFn        fnMouse;
@property (nonatomic, assign) CSBIndigoMessageForMouseEdgeFn    fnMouseEdge;
@property (nonatomic, assign) CSBIndigoMessageForHIDArbitraryFn fnHIDArbitrary;
@property (nonatomic, assign) CSBIndigoMessageForDigitalCrownFn fnCrown;

// The simulator's HID daemon, when the client was given messages for it.
@property (nonatomic, strong) SimDevice *device;
@property (nonatomic, strong, nullable) id<CSBRemoteHIDMessageBuilding> remoteMessages;
/// The anchored touch connection. Replaced, never reopened, when lost.
@property (atomic, strong, nullable) SimRemoteHIDChannel *remoteTouch;
/// The touchscreen service serving each display, as the anchor's reply
/// listed them. Replaced with the connection.
@property (atomic, copy) NSDictionary<NSString *, NSNumber *> *remoteTouchServices;
@property (nonatomic, strong, nullable) SimRemoteHIDChannel *remoteButtons;
/// Opened with the first key, since registering the keyboard is what tells
/// the simulator a keyboard is attached.
@property (nonatomic, strong, nullable) SimRemoteHIDChannel *remoteKeyboard;
@property (nonatomic, assign) uint64_t remoteKeyboardServiceID;
/// Why keys stay on the Indigo path, once registering the keyboard failed.
@property (nonatomic, copy, nullable) NSString *remoteKeyboardFailure;
/// Every HID usage held down, since a keyboard report carries the full set.
@property (nonatomic, strong) NSMutableSet<NSNumber *> *pressedUsages;
@property (atomic, copy, readwrite, nullable) NSString *remoteHIDUnavailableReason;
/// When the daemon's connections were last tried, so a client attached
/// before the daemon was reachable tries again without trying on every send.
@property (nonatomic, assign) CFAbsoluteTime remoteAttemptTime;
@end

@implementation SimHIDClient

#pragma mark Construction

+ (nullable SimDevice *)_lookupDeviceForUDID:(NSString *)udid error:(NSError **)error {
    Class ctxCls = NSClassFromString(@"SimServiceContext");
    if (!ctxCls) {
        if (error) {
            *error = [NSError errorWithDomain:CSBHIDClientErrorDomain code:CSBHIDClientErrorContext userInfo:@{
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
            *error = inner ?: [NSError errorWithDomain:CSBHIDClientErrorDomain
                                                  code:CSBHIDClientErrorContext userInfo:@{
                NSLocalizedDescriptionKey: @"sharedServiceContextForDeveloperDir failed",
            }];
        }
        return nil;
    }
    SimDeviceSet *set = [ctx defaultDeviceSetWithError:&inner];
    if (!set) {
        if (error) {
            *error = inner ?: [NSError errorWithDomain:CSBHIDClientErrorDomain
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
        *error = [NSError errorWithDomain:CSBHIDClientErrorDomain
                                     code:CSBHIDClientErrorDeviceNotFound
                                 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Device with UDID %@ not found", udid],
        }];
    }
    return nil;
}

+ (nullable instancetype)clientForUDID:(NSString *)udid error:(NSError **)error {
    return [self clientForUDID:udid remoteMessages:nil error:error];
}

+ (nullable instancetype)clientForUDID:(NSString *)udid
                        remoteMessages:(nullable id<CSBRemoteHIDMessageBuilding>)remoteMessages
                                 error:(NSError **)error {
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
            *error = [NSError errorWithDomain:CSBHIDClientErrorDomain
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
            *error = inner ?: [NSError errorWithDomain:CSBHIDClientErrorDomain
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
            *error = [NSError errorWithDomain:CSBHIDClientErrorDomain
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
    client.ledger = [SimHIDSendLedger new];
    client.device = device;
    client.pressedUsages = [NSMutableSet set];
    if (remoteMessages) {
        client.remoteMessages = remoteMessages;
        [client _openRemoteChannels];
    } else {
        client.remoteHIDUnavailableReason = @"no messages for the simulator's HID daemon were supplied";
    }
    return client;
}

#pragma mark Remote HID

/// How long the daemon gets to answer an opening request. It builds the
/// session's services before answering, which takes about half a second.
static const NSTimeInterval kCSBRemoteRequestTimeout = 3.0;

/// Open the touch and button connections. A touch connection that can't be
/// anchored leaves every input on the Indigo path, with the reason kept.
- (void)_openRemoteChannels {
    self.remoteAttemptTime = CFAbsoluteTimeGetCurrent();
    NSError *touchError = nil;
    self.remoteTouch = [self _openAnchoredTouchChannelWithError:&touchError];
    if (!self.remoteTouch) {
        self.remoteHIDUnavailableReason = touchError.localizedDescription ?: @"the touch service could not be opened";
        return;
    }
    self.remoteHIDUnavailableReason = nil;
    self.remoteButtons = [SimRemoteHIDChannel channelForDevice:self.device
                                                       service:self.remoteMessages.buttonServiceName
                                                         error:NULL];
}

/// How long a client that couldn't reach the daemon waits before trying
/// again. A simulator attached while booting may not have its services up.
static const CFTimeInterval kCSBRemoteRetryInterval = 5.0;

- (void)retryRemoteHIDIfDue {
    if (!self.remoteMessages || self.remoteTouch) return;
    if (CFAbsoluteTimeGetCurrent() - self.remoteAttemptTime < kCSBRemoteRetryInterval) return;
    [self _openRemoteChannels];
}

- (nullable SimRemoteHIDChannel *)_openAnchoredTouchChannelWithError:(NSError **)error {
    SimRemoteHIDChannel *channel = [SimRemoteHIDChannel channelForDevice:self.device
                                                                 service:self.remoteMessages.touchServiceName
                                                                   error:error];
    if (!channel) return nil;
    xpc_object_t reply = [channel sendRequest:[self.remoteMessages sessionAnchor]
                                      timeout:kCSBRemoteRequestTimeout
                                        error:error];
    if (!reply) {
        [channel invalidate];
        return nil;
    }
    self.remoteTouchServices = [self.remoteMessages touchscreenServicesFromAnchorReply:reply];
    return channel;
}

- (BOOL)sendsThroughRemoteHID {
    return self.remoteTouch != nil;
}

/// The live touch connection, replacing a lost one, or nil when this client
/// doesn't use one.
- (nullable SimRemoteHIDChannel *)_liveRemoteTouchWithError:(NSError **)error {
    SimRemoteHIDChannel *channel = self.remoteTouch;
    if (!channel) return nil;
    if (!channel.lost) return channel;
    SimRemoteHIDChannel *replacement = [self _openAnchoredTouchChannelWithError:error];
    if (replacement) self.remoteTouch = replacement;
    return replacement;
}

/// The keyboard connection, registering the keyboard on first use. Nil, with
/// the failure kept, once registration has failed: keys then stay on the
/// Indigo path rather than paying the registration wait on every key.
- (nullable SimRemoteHIDChannel *)_liveRemoteKeyboard {
    if (!self.remoteTouch || self.remoteKeyboardFailure) return nil;
    if (self.remoteKeyboard && !self.remoteKeyboard.lost) return self.remoteKeyboard;
    NSError *error = nil;
    SimRemoteHIDChannel *channel = [SimRemoteHIDChannel channelForDevice:self.device
                                                                 service:self.remoteMessages.touchServiceName
                                                                   error:&error];
    xpc_object_t reply = channel ? [channel sendRequest:[self.remoteMessages keyboardRegistration]
                                                timeout:kCSBRemoteRequestTimeout
                                                  error:&error] : nil;
    if (!reply) {
        [channel invalidate];
        self.remoteKeyboard = nil;
        self.remoteKeyboardFailure = error.localizedDescription ?: @"the keyboard could not be registered";
        return nil;
    }
    self.remoteKeyboardServiceID = [self.remoteMessages keyboardServiceIDFromReply:reply];
    self.remoteKeyboard = channel;
    return channel;
}

/// Send `message` over `channel` through the ledger, the same admission and
/// one-second wait an Indigo send gets.
- (BOOL)_sendRemote:(xpc_object_t)message
            channel:(SimRemoteHIDChannel *)channel
            release:(BOOL)isRelease
              error:(NSError **)error {
    dispatch_queue_t queue = self.sendQueue;
    return [self _sendAdmitted:^(void (^complete)(NSError *)) {
        [channel sendMessage:message completionQueue:queue completion:complete];
    } release:isRelease error:error];
}

/// The touchscreen service a touch goes to: the one the daemon lists for the
/// panel's display, or the one its screen id names, or the main one.
- (uint64_t)_remoteTouchServiceID {
    NSString *display = self.touchScreenUniqueID;
    NSNumber *listed = display ? self.remoteTouchServices[display] : nil;
    if (listed) return listed.unsignedLongLongValue;
    return [self.remoteMessages touchscreenServiceIDForScreenID:self.touchScreenID];
}

/// Send a touch over the touch connection, replacing it once if it was lost.
/// NO without an error when this client sends touches through Indigo.
- (BOOL)_sendRemoteTouch:(xpc_object_t)message release:(BOOL)isRelease handled:(BOOL *)handled error:(NSError **)error {
    *handled = NO;
    if (!self.remoteTouch) return NO;
    *handled = YES;
    SimRemoteHIDChannel *channel = [self _liveRemoteTouchWithError:error];
    if (!channel) return NO;
    return [self _sendRemote:message channel:channel release:isRelease error:error];
}

#pragma mark Send helper

/// Send an Indigo message through the ledger (see `_sendAdmitted:`).
/// `freeWhenDone:YES` hands ownership of the message buffer to SimulatorKit,
/// which queues every send behind the ones before it and sends with no
/// timeout.
- (BOOL)_sendMessage:(IndigoMessage *)message release:(BOOL)isRelease error:(NSError **)error {
    if (!message) {
        if (error) {
            *error = [NSError errorWithDomain:CSBHIDClientErrorDomain
                                         code:CSBHIDClientErrorNilMessage
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"Indigo message builder returned NULL",
            }];
        }
        return NO;
    }
    __block BOOL submitted = NO;
    SimDeviceLegacyClient *legacy = self.legacyClient;
    dispatch_queue_t queue = self.sendQueue;
    BOOL ok = [self _sendAdmitted:^(void (^complete)(NSError *)) {
        submitted = YES;
        [legacy sendWithMessage:message freeWhenDone:YES completionQueue:queue completion:complete];
    } release:isRelease error:error];
    // Never handed to SimulatorKit, so the buffer is still ours.
    if (!submitted) free(message);
    return ok;
}

/// Admit a send to the ledger, hand it to `submit`, and wait up to one second
/// for the completion `submit` reports.
///
/// Neither transport cancels a send, so a late completion is not a failed
/// send. Past the wait this returns a timeout error, and the send stays in the
/// ledger until it does complete. Until then every send that isn't a release
/// is refused rather than queued behind it, so input doesn't pile up to
/// arrive late. A release is still sent: queued behind the stalled send, it
/// lifts what is down once that send completes. `submit` is not called when
/// the ledger refuses the send.
- (BOOL)_sendAdmitted:(void (NS_NOESCAPE ^)(void (^complete)(NSError * _Nullable)))submit
              release:(BOOL)isRelease
                error:(NSError **)error {
    uint64_t ticket = 0;
    if (![self.ledger admitSendAsRelease:isRelease ticket:&ticket error:error]) return NO;
    SimHIDSendLedger *ledger = self.ledger;
    __block NSError *cbError = nil;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    submit(^(NSError *e) {
        cbError = e;
        [ledger completeTicket:ticket error:e];
        dispatch_semaphore_signal(sema);
    });
    long timedOut = dispatch_semaphore_wait(sema,
        dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC));
    if (timedOut != 0 && ![ledger abandonWaitForTicket:ticket]) {
        // The completion ran between the deadline and the abandon, so this
        // send's outcome is already in `cbError` and its signal is on the
        // way. Collect both and report it like any completion; abandoning
        // now would hand a failure to nobody.
        dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
        timedOut = 0;
    }
    if (timedOut != 0) {
        if (error) {
            *error = [NSError errorWithDomain:CSBHIDClientErrorDomain
                                         code:CSBHIDClientErrorSendTimeout
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"HID send did not complete within 1s; it was not cancelled "
                                            "and may still complete",
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

- (void)whenSendsSettleWithCompletionHandler:(void (^)(NSError * _Nullable))completionHandler {
    [self.ledger whenSettledOnQueue:self.sendQueue handler:completionHandler];
}

- (void)whenSendsDrainWithHandler:(void (^)(void))handler {
    [self.ledger whenDrainedOnQueue:self.sendQueue handler:handler];
}

- (NSUInteger)outstandingSendCount {
    return self.ledger.outstandingSendCount;
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
            *error = [NSError errorWithDomain:CSBHIDClientErrorDomain
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
            *error = inner ?: [NSError errorWithDomain:CSBHIDClientErrorDomain
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
        && [error.domain isEqualToString:CSBHIDClientErrorDomain]
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
                  release:(BOOL)isRelease
                    error:(NSError **)error {
    NSError *sendError = nil;
    if ([self _sendMessage:builder() release:isRelease error:&sendError]) return YES;
    if (CSBIsDeviceDisconnected(sendError)) {
        NSError *reconnectError = nil;
        if ([self _reconnectLegacyClientWithError:&reconnectError]) {
            return [self _sendMessage:builder() release:isRelease error:error];
        }
        if (error) *error = reconnectError ?: sendError;
        return NO;
    }
    if (CSBIsNilMessage(sendError)) {
        if (error) {
            *error = [NSError errorWithDomain:CSBHIDClientErrorDomain
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

#pragma mark Touch target

/// The flag Indigo ORs into a `screenID` to address a contact to that panel.
static const unsigned int kCSBIndigoScreenTargetFlag = 0x40000000;

/// The Indigo target for a touch contact: the screen-based target for
/// `touchScreenID` when one is set, otherwise the fixed digitizer target.
- (int)_touchTarget {
    unsigned int screenID = self.touchScreenID;
    if (screenID == 0) return ButtonEventTargetDigitizer;
    return (int)(screenID | kCSBIndigoScreenTargetFlag);
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
    IndigoMessage *base = self.fnMouse(&pt, NULL, [self _touchTarget], direction, NO);
    if (!base) return NULL;
    base->payload.event.touch.xRatio = ratio.x;
    base->payload.event.touch.yRatio = ratio.y;

    size_t messageSize = sizeof(IndigoMessage) + sizeof(IndigoPayload);
    IndigoMessage *out = calloc(1, messageSize);
    out->innerSize = sizeof(IndigoPayload);
    out->eventType = IndigoEventTypeTouch;
    out->payload.eventKind = 0x0000000b;
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
    BOOL handled = NO;
    BOOL sent = [self _sendRemoteTouch:[self.remoteMessages touchWithContact:YES x:point.x y:point.y serviceID:[self _remoteTouchServiceID]]
                               release:NO handled:&handled error:error];
    if (handled) return sent;
    return [self _sendBuiltMessage:^IndigoMessage *{
        return [self _buildTouchMessageAtRatio:point direction:ButtonEventTypeDown];
    } release:NO error:error];
}

- (BOOL)tapUpAtNormalizedPoint:(CGPoint)point error:(NSError **)error {
    BOOL handled = NO;
    BOOL sent = [self _sendRemoteTouch:[self.remoteMessages touchWithContact:NO x:point.x y:point.y serviceID:[self _remoteTouchServiceID]]
                               release:YES handled:&handled error:error];
    if (handled) return sent;
    return [self _sendBuiltMessage:^IndigoMessage *{
        return [self _buildTouchMessageAtRatio:point direction:ButtonEventTypeUp];
    } release:YES error:error];
}

#pragma mark Edge-tagged touch (system gestures: home / App Switcher)

/// Like `_buildTouchMessageAtRatio:direction:`, but built through the
/// true 6-arg `fnMouseEdge` so the touch carries an originating screen
/// `edge` (`IndigoHIDEdge`), which is what routes it to SpringBoard's
/// system edge-gesture recognizer instead of app content. The edge lands
/// in the high bytes of `IndigoTouch.eventMask` (0x38), alongside the
/// `IOHIDDigitizerEventMask` bits the plain path also writes there.
///
/// `eventType` carries a down or an up, never a motion phase: the builder
/// returns NULL for every motion `NSEventType` (see the `fnMouseEdge`
/// typedef). `NSSize` is passed zero because the builder reads it only to
/// scale the ratio fields, which are overwritten below.
- (IndigoMessage *)_buildEdgeTouchMessageAtRatio:(CGPoint)ratio
                                       eventType:(int)eventType
                                            edge:(int)edge {
    CGPoint pt = ratio;
    IndigoMessage *base = self.fnMouseEdge(&pt, NULL, [self _touchTarget], (NSUInteger)eventType, CGSizeZero,
                                           (NSInteger)edge);
    if (!base) return NULL;
    base->payload.event.touch.xRatio = ratio.x;
    base->payload.event.touch.yRatio = ratio.y;

    size_t messageSize = sizeof(IndigoMessage) + sizeof(IndigoPayload);
    IndigoMessage *out = calloc(1, messageSize);
    out->innerSize = sizeof(IndigoPayload);
    out->eventType = IndigoEventTypeTouch;
    out->payload.eventKind = 0x0000000b;
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

/// Send an edge-tagged touch phase over the touch connection. NO with
/// `handled` clear when touches go through Indigo.
- (BOOL)_sendRemoteEdgeTouchAt:(CGPoint)point
                          edge:(NSInteger)edge
                       contact:(BOOL)contact
                       handled:(BOOL *)handled
                         error:(NSError **)error {
    *handled = NO;
    xpc_object_t message = [self.remoteMessages gestureTouchWithContact:contact
                                                                      x:point.x
                                                                      y:point.y
                                                                   edge:edge
                                                               serviceID:[self _remoteTouchServiceID]];
    return [self _sendRemoteTouch:message release:!contact handled:handled error:error];
}

- (BOOL)edgeTouchDownAtNormalizedPoint:(CGPoint)point edge:(NSInteger)edge error:(NSError **)error {
    BOOL handled = NO;
    BOOL sent = [self _sendRemoteEdgeTouchAt:point edge:edge contact:YES handled:&handled error:error];
    if (handled) return sent;
    return [self _sendBuiltMessage:^IndigoMessage *{
        return [self _buildEdgeTouchMessageAtRatio:point eventType:0x1 edge:(int)edge];
    } release:NO error:error];
}

- (BOOL)edgeTouchMoveAtNormalizedPoint:(CGPoint)point edge:(NSInteger)edge error:(NSError **)error {
    // A move is a re-down at the new point, the continued-contact convention
    // the plain-touch drag already relies on. The builder has no motion event
    // type to offer: every one of them returns NULL.
    BOOL handled = NO;
    BOOL sent = [self _sendRemoteEdgeTouchAt:point edge:edge contact:YES handled:&handled error:error];
    if (handled) return sent;
    return [self _sendBuiltMessage:^IndigoMessage *{
        return [self _buildEdgeTouchMessageAtRatio:point eventType:0x1 edge:(int)edge];
    } release:NO error:error];
}

- (BOOL)edgeTouchUpAtNormalizedPoint:(CGPoint)point edge:(NSInteger)edge error:(NSError **)error {
    BOOL handled = NO;
    BOOL sent = [self _sendRemoteEdgeTouchAt:point edge:edge contact:NO handled:&handled error:error];
    if (handled) return sent;
    return [self _sendBuiltMessage:^IndigoMessage *{
        return [self _buildEdgeTouchMessageAtRatio:point eventType:0x2 edge:(int)edge];
    } release:YES error:error];
}

+ (BOOL)isEdgeTouchBuildableWithError:(NSError **)error {
    if (![CoreSimulatorLoader loadSimulatorKitWithError:error]) return NO;
    CSBIndigoMessageForMouseEdgeFn fn = (CSBIndigoMessageForMouseEdgeFn)
        dlsym(RTLD_DEFAULT, "IndigoHIDMessageForMouseNSEvent");
    if (!fn) {
        if (error) {
            *error = [NSError errorWithDomain:CSBHIDClientErrorDomain
                                         code:CSBHIDClientErrorIndigoSymsMissing
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"IndigoHIDMessageForMouseNSEvent is unavailable "
                    @"on this host; no touch input can be built.",
            }];
        }
        return NO;
    }
    // `edgeTouchMove` re-sends the down event type, so down and up between
    // them cover every phase the system-gesture path emits. Each is built
    // twice, tagged and untagged, because a builder that still returns a
    // message while quietly dropping the edge argument would leave the
    // gesture reaching the foreground app instead of SpringBoard, which
    // looks like nothing happening rather than like a failure.
    const int phases[] = {0x1, 0x2};
    for (size_t i = 0; i < sizeof(phases) / sizeof(phases[0]); i++) {
        CGPoint taggedPoint = CGPointMake(0.5, 0.99);
        CGPoint untaggedPoint = CGPointMake(0.5, 0.99);
        // 3 is the bottom edge, the live-confirmed value the App Switcher
        // rides on; 0 is the untagged touch the plain path sends.
        IndigoMessage *tagged = fn(&taggedPoint, NULL, ButtonEventTargetDigitizer, (NSUInteger)phases[i],
                                   CGSizeZero, (NSInteger)3);
        IndigoMessage *untagged = fn(&untaggedPoint, NULL, ButtonEventTargetDigitizer, (NSUInteger)phases[i],
                                     CGSizeZero, (NSInteger)0);
        BOOL built = (tagged != NULL && untagged != NULL);
        // The edge lands in the high bytes of `eventMask`, so a tagged build
        // that matches its untagged twin there never carried the tag.
        BOOL tagLanded = built && tagged->payload.event.touch.eventMask
                               != untagged->payload.event.touch.eventMask;
        if (tagged) free(tagged);
        if (untagged) free(untagged);
        if (!built) {
            if (error) {
                *error = [NSError errorWithDomain:CSBHIDClientErrorDomain
                                             code:CSBHIDClientErrorNilMessage
                                         userInfo:@{
                    NSLocalizedDescriptionKey: [NSString stringWithFormat:
                        @"IndigoHIDMessageForMouseNSEvent returned NULL for NSEventType %d; "
                        @"this host's SimulatorKit no longer accepts an argument the "
                        @"edge-tagged system-gesture path depends on.", phases[i]],
                }];
            }
            return NO;
        }
        if (!tagLanded) {
            if (error) {
                *error = [NSError errorWithDomain:CSBHIDClientErrorDomain
                                             code:CSBHIDClientErrorNilMessage
                                         userInfo:@{
                    NSLocalizedDescriptionKey: [NSString stringWithFormat:
                        @"IndigoHIDMessageForMouseNSEvent built NSEventType %d but the "
                        @"IndigoHIDEdge argument left the touch payload unchanged; this "
                        @"host's SimulatorKit no longer carries the edge tag, so system "
                        @"gestures would reach the foreground app instead.", phases[i]],
                }];
            }
            return NO;
        }
    }
    return YES;
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
    IndigoMessage *message = self.fnMouse(&r1, &r2, [self _touchTarget], direction, NO);
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
    BOOL handled = NO;
    BOOL sent = [self _sendRemoteTouch:[self.remoteMessages twoFingerTouchWithContact:YES first:f1 second:f2
                                                                             serviceID:[self _remoteTouchServiceID]]
                               release:NO handled:&handled error:error];
    if (handled) return sent;
    return [self _sendBuiltMessage:^IndigoMessage *{
        return [self _buildTwoFingerTouchMessageAtRatio1:f1
                                                  ratio2:f2
                                               direction:ButtonEventTypeDown];
    } release:NO error:error];
}

- (BOOL)twoFingerUpAtFinger1:(CGPoint)f1 finger2:(CGPoint)f2 error:(NSError **)error {
    BOOL handled = NO;
    BOOL sent = [self _sendRemoteTouch:[self.remoteMessages twoFingerTouchWithContact:NO first:f1 second:f2
                                                                             serviceID:[self _remoteTouchServiceID]]
                               release:YES handled:&handled error:error];
    if (handled) return sent;
    return [self _sendBuiltMessage:^IndigoMessage *{
        return [self _buildTwoFingerTouchMessageAtRatio1:f1
                                                  ratio2:f2
                                               direction:ButtonEventTypeUp];
    } release:YES error:error];
}

#pragma mark Keyboard

/// Whether `error` is the wait on a send giving up, which means the send was
/// handed to its transport and may still complete.
static BOOL CSBIsSendTimeout(NSError *error) {
    return [error.domain isEqualToString:CSBHIDClientErrorDomain] && error.code == CSBHIDClientErrorSendTimeout;
}

/// Send the keyboard report for the held set with `usage` added or removed.
///
/// A report carries the whole held set, and reports go out in order, so the
/// set must describe the last report handed to the transport: that is the
/// state the simulator ends up in. It changes when the report is submitted,
/// including when the wait on it times out, because a timed-out report still
/// lands. It stays as it was only when the report was never submitted. NO
/// with `handled` clear when keys go through Indigo.
- (BOOL)_sendRemoteKey:(unsigned int)usage down:(BOOL)down handled:(BOOL *)handled error:(NSError **)error {
    *handled = NO;
    SimRemoteHIDChannel *channel = [self _liveRemoteKeyboard];
    if (!channel) return NO;
    *handled = YES;
    NSMutableSet<NSNumber *> *next = [self.pressedUsages mutableCopy];
    if (down) {
        [next addObject:@(usage)];
    } else {
        [next removeObject:@(usage)];
    }
    xpc_object_t report = [self.remoteMessages keyboardReportWithPressedUsages:next
                                                                     serviceID:self.remoteKeyboardServiceID];
    NSError *sendError = nil;
    BOOL sent = [self _sendRemote:report channel:channel release:!down error:&sendError];
    if (sent || CSBIsSendTimeout(sendError)) self.pressedUsages = next;
    if (!sent && error) *error = sendError;
    return sent;
}

- (BOOL)keyDownWithKeyCode:(unsigned int)keyCode error:(NSError **)error {
    BOOL handled = NO;
    BOOL sent = [self _sendRemoteKey:keyCode down:YES handled:&handled error:error];
    if (handled) return sent;
    return [self _sendBuiltMessage:^IndigoMessage *{
        return self.fnKeyboard((int)keyCode, ButtonEventTypeDown);
    } release:NO error:error];
}

- (BOOL)keyUpWithKeyCode:(unsigned int)keyCode error:(NSError **)error {
    BOOL handled = NO;
    BOOL sent = [self _sendRemoteKey:keyCode down:NO handled:&handled error:error];
    if (handled) return sent;
    return [self _sendBuiltMessage:^IndigoMessage *{
        return self.fnKeyboard((int)keyCode, ButtonEventTypeUp);
    } release:YES error:error];
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
///
/// The vendored `Indigo.h` says this cannot work: that the guest drops a HID
/// usage addressed to `ButtonEventTargetHardware` with no log line and no
/// error, and that only `ButtonEventTargetDigitizer` reaches the handler
/// acting on usages. That is not what the guest does here. It logs the usage
/// and drives the whole activation chain through SpringBoard and
/// `SiriActivationService` to a presented Siri. The vendored header is a
/// verbatim upstream snapshot and is not patched to match; trust this call
/// site over its claim, and re-check both if Siri stops responding on a
/// newer runtime.
- (BOOL)_pressVoiceCommandWithError:(NSError **)error {
    BOOL ok = [self _sendBuiltMessage:^IndigoMessage *{
        return self.fnHIDArbitrary(ButtonEventTargetHardware, kCSBConsumerUsagePage,
                                   kCSBVoiceCommandUsage, ButtonEventTypeDown);
    } release:NO error:error];
    if (!ok) return NO;
    usleep(50000);  // 50ms between down and up, matching the other buttons.
    return [self _sendBuiltMessage:^IndigoMessage *{
        return self.fnHIDArbitrary(ButtonEventTargetHardware, kCSBConsumerUsagePage,
                                   kCSBVoiceCommandUsage, ButtonEventTypeUp);
    } release:YES error:error];
}

/// Send one phase of `button` over the button connection when the
/// vocabulary has an event for it. NO with `handled` clear otherwise.
- (BOOL)_sendRemoteButton:(CSBHardwareButton)button down:(BOOL)down handled:(BOOL *)handled error:(NSError **)error {
    *handled = NO;
    SimRemoteHIDChannel *channel = self.remoteButtons;
    xpc_object_t event = [self.remoteMessages buttonEventForButton:button down:down];
    if (!channel || !event) return NO;
    *handled = YES;
    if (channel.lost) {
        SimRemoteHIDChannel *replacement = [SimRemoteHIDChannel channelForDevice:self.device
                                                                         service:self.remoteMessages.buttonServiceName
                                                                           error:error];
        if (!replacement) return NO;
        self.remoteButtons = replacement;
        channel = replacement;
    }
    return [self _sendRemote:event channel:channel release:!down error:error];
}

- (BOOL)pressHardwareButton:(CSBHardwareButton)button error:(NSError **)error {
    BOOL handled = NO;
    NSInteger presses = MAX(1, [self.remoteMessages pressCountForButton:button]);
    for (NSInteger press = 0; press < presses; press++) {
        if (press > 0) usleep(100000);  // Within the double-press window.
        BOOL pressed = [self _sendRemoteButton:button down:YES handled:&handled error:error];
        if (!handled) break;
        if (!pressed) return NO;
        usleep(50000);  // 50ms between down and up, matching the Indigo path.
        if (![self _sendRemoteButton:button down:NO handled:&handled error:error]) return NO;
    }
    if (handled) return YES;
    if (button == CSBHardwareButtonSiri) {
        return [self _pressVoiceCommandWithError:error];
    }
    int source = [SimHIDClient _indigoSourceForButton:button];
    BOOL ok = [self _sendBuiltMessage:^IndigoMessage *{
        return self.fnButton(source, ButtonEventTypeDown, ButtonEventTargetHardware);
    } release:NO error:error];
    if (!ok) return NO;
    usleep(50000);  // 50ms between down and up, matching idb's timing.
    return [self _sendBuiltMessage:^IndigoMessage *{
        return self.fnButton(source, ButtonEventTypeUp, ButtonEventTargetHardware);
    } release:YES error:error];
}

- (BOOL)releaseHardwareButton:(CSBHardwareButton)button error:(NSError **)error {
    // Up phase only; no preceding down. Safely neutralizes a button whose
    // press+release composite may have left it stuck down, without the risk
    // a full re-press carries (firing a fresh action if the original failed
    // before down landed).
    BOOL handled = NO;
    BOOL released = [self _sendRemoteButton:button down:NO handled:&handled error:error];
    if (handled) return released;
    if (button == CSBHardwareButtonSiri) {
        return [self _sendBuiltMessage:^IndigoMessage *{
            return self.fnHIDArbitrary(ButtonEventTargetHardware, kCSBConsumerUsagePage,
                                       kCSBVoiceCommandUsage, ButtonEventTypeUp);
        } release:YES error:error];
    }
    int source = [SimHIDClient _indigoSourceForButton:button];
    return [self _sendBuiltMessage:^IndigoMessage *{
        return self.fnButton(source, ButtonEventTypeUp, ButtonEventTargetHardware);
    } release:YES error:error];
}

#pragma mark Digital Crown

+ (BOOL)isDigitalCrownAvailable {
    if (![CoreSimulatorLoader loadSimulatorKitWithError:NULL]) return NO;
    return dlsym(RTLD_DEFAULT, "IndigoHIDMessageForDigitalCrownEvent") != NULL;
}

/// Rotate the watchOS Digital Crown by a signed delta via SimulatorKit's
/// dedicated `IndigoHIDMessageForDigitalCrownEvent`. A single send (no
/// down/up pair, since the crown is a continuous rotary, not a button). Sign is
/// direction; magnitude is distance. Routed through `_sendBuiltMessage:` for
/// the same disconnect-recovery as every other send.
- (BOOL)rotateCrownByDelta:(double)delta error:(NSError **)error {
    if (!self.fnCrown) {
        if (error) {
            *error = [NSError errorWithDomain:CSBHIDClientErrorDomain
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
    } release:NO error:error];
}

@end
