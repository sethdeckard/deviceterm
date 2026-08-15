// SPDX-License-Identifier: GPL-3.0-or-later

#import "SimDeviceNotifier.h"
#import "CoreSimulatorLoader.h"

#import <CoreSimulator/SimServiceContext.h>
#import <CoreSimulator/SimDeviceSet.h>
#import <CoreSimulator/SimDevice.h>
#import <CoreSimulator/SimDeviceNotifier-Protocol.h>

static NSString *const kCSBErrorDomain = @"CoreSimulatorBridge.SimDeviceNotifier";

typedef NS_ENUM(NSInteger, CSBNotifierError) {
    CSBNotifierErrorLoadFailed         = 30,
    CSBNotifierErrorContextUnavailable = 31,
    CSBNotifierErrorDeviceSetFailed    = 32,
    CSBNotifierErrorRegisterFailed     = 33,
};

#pragma mark - Notification dict keys
//
// CoreSimulator's notification payload is an untyped NSDictionary
// whose keys aren't published in any header we can rely on.
// Verified empirically on macOS 26.4 / Xcode 26.4 via the live
// track with `DEVICETERM_DEBUG_NOTIFIER=1`; the shape lines up with
// FBSimulatorControl's reverse-engineered constants. Should Apple
// rename anything, the live track's "no matching .shutdown
// state-change" assertion fails immediately with the observed
// dict trace. Caller can re-run with `DEVICETERM_DEBUG_NOTIFIER=1`
// for full key+type dumps.

static NSString *const kCSBNKeyNotificationName = @"notification";
static NSString *const kCSBNKeyNewState          = @"new_state";
static NSString *const kCSBNKeyPreviousState     = @"prev_state";
static NSString *const kCSBNKeyDevice            = @"device";

#pragma mark - CSBNotifierEvent

@interface CSBNotifierEvent ()
@property (nonatomic, readwrite) CSBNotifierEventKind kind;
@property (nonatomic, copy, readwrite) NSString *udid;
@property (nonatomic, readwrite) CSBSimState newState;
@property (nonatomic, readwrite) CSBSimState previousState;
@property (nonatomic, copy, readwrite) NSString *rawName;
@end

@implementation CSBNotifierEvent

// `udid` and `rawName` are declared `nonnull` in the header (the
// whole header sits under NS_ASSUME_NONNULL), so Swift imports
// them as plain `String`. NSObject's default `-init` leaves the
// underlying ivars as `nil`, and any Swift caller that constructs
// `CSBNotifierEvent()` and reads either property would trap. Set
// the empty-string defaults explicitly here; `CSBNEventFromDict`
// overwrites both before delivering an event to the handler.
- (instancetype)init {
    self = [super init];
    if (self) {
        _udid = @"";
        _rawName = @"";
        _newState = CSBSimStateUnknown;
        _previousState = CSBSimStateUnknown;
    }
    return self;
}

@end

#pragma mark - State normalisation
//
// Repeated here (kept in sync with `SimDeviceHandle._normalizeState`)
// because the notifier intentionally doesn't depend on
// `SimDeviceHandle`'s private impl. If Apple ever extends the state
// enum, both call sites must be updated together; the live test
// will fail loudly if the inventory drifts.

static CSBSimState CSBNNormalizeState(unsigned long long raw) {
    if (raw <= 4) return (CSBSimState)raw;
    return CSBSimStateUnknown;
}

static CSBSimState CSBNStateFromNumber(NSNumber *value) {
    if (![value isKindOfClass:NSNumber.class]) return CSBSimStateUnknown;
    return CSBNNormalizeState((unsigned long long)value.unsignedLongLongValue);
}

#pragma mark - Device extraction

/// Locate the `SimDevice` referenced by a notification dict. Tries
/// the documented `device` key first, then scans values for any
/// `SimDevice` instance, defensive against minor key renames.
static SimDevice * _Nullable CSBNExtractDevice(NSDictionary *info) {
    id direct = info[kCSBNKeyDevice];
    if ([direct isKindOfClass:NSClassFromString(@"SimDevice")]) {
        return (SimDevice *)direct;
    }
    for (id value in info.objectEnumerator) {
        if ([value isKindOfClass:NSClassFromString(@"SimDevice")]) {
            return (SimDevice *)value;
        }
    }
    return nil;
}

static NSString *CSBNUDIDStringFromDevice(SimDevice *dev) {
    NSUUID *uuid = dev.UDID;
    NSString *s = uuid.UUIDString ?: @"";
    return s.lowercaseString;
}

#pragma mark - Dict → Event

static CSBNotifierEvent *CSBNEventFromDict(NSDictionary *info) {
    CSBNotifierEvent *event = [CSBNotifierEvent new];
    NSString *rawName = info[kCSBNKeyNotificationName];
    if (![rawName isKindOfClass:NSString.class]) rawName = @"";

    // Dict-key archaeology diagnostic: when the live track's
    // "no matching .shutdown" assertion fires (Apple renames a
    // key, or the dict shape drifts), re-run with
    // `DEVICETERM_DEBUG_NOTIFIER=1 make test-live` to dump every
    // key + value class to stderr. Off by default so production
    // doesn't log.
    if (getenv("DEVICETERM_DEBUG_NOTIFIER")) {
        NSMutableArray<NSString *> *keyTypes = [NSMutableArray array];
        for (id key in info.allKeys) {
            id value = info[key];
            [keyTypes addObject:[NSString stringWithFormat:@"%@<%@>",
                                  key, NSStringFromClass([value class])]];
        }
        fprintf(stderr,
                "[CSBDeviceNotifier] dict keys: %s\n",
                [keyTypes componentsJoinedByString:@", "].UTF8String);
    }
    event.rawName = rawName;

    SimDevice *dev = CSBNExtractDevice(info);
    event.udid = dev ? CSBNUDIDStringFromDevice(dev) : @"";

    // Discriminate by the *presence* of a numeric `new_state`
    // rather than matching the `notification` name string, because
    // CoreSimulator emits several notifications on a transition
    // (`device_state`, `SimDeviceNotificationType_BootStatus`,
    // etc.); the state-change variant is uniquely identified by
    // carrying both a device and a numeric new state.
    id rawNewState = info[kCSBNKeyNewState];
    BOOL isStateChange = [rawNewState isKindOfClass:NSNumber.class] && dev != nil;
    if (isStateChange) {
        event.kind = CSBNotifierEventKindStateChanged;
        event.newState = CSBNStateFromNumber((NSNumber *)rawNewState);
        event.previousState = CSBNStateFromNumber(info[kCSBNKeyPreviousState]);
        // Belt-and-suspenders: if the dict's numeric raw is
        // outside the known inventory, fall back to the live
        // device state. Racy against another transition but the
        // only authoritative source if Apple ever extends the
        // enum.
        if (event.newState == CSBSimStateUnknown) {
            event.newState = CSBNNormalizeState(dev.state);
        }
    } else {
        event.kind = CSBNotifierEventKindOther;
        event.newState = CSBSimStateUnknown;
        event.previousState = CSBSimStateUnknown;
    }
    return event;
}

#pragma mark - Service-context resolution
//
// Mirrors `SimDeviceHandle`'s private helpers. Kept inline rather
// than refactored into a shared util because the bridge file
// boundary is the unit of "code that touches private API". Sharing
// the helper across files would diffuse the audit surface.

static SimServiceContext * _Nullable CSBNResolveContext(NSError **error) {
    Class ctxCls = NSClassFromString(@"SimServiceContext");
    if (!ctxCls) {
        if (error) {
            *error = [NSError errorWithDomain:kCSBErrorDomain
                                         code:CSBNotifierErrorContextUnavailable
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"SimServiceContext class not found; framework load incomplete?",
            }];
        }
        return nil;
    }
    NSString *devDir = [CoreSimulatorLoader resolveDeveloperDir];
    NSError *inner = nil;
    SimServiceContext *ctx = [ctxCls sharedServiceContextForDeveloperDir:devDir error:&inner];
    if (!ctx && error) {
        *error = inner ?: [NSError errorWithDomain:kCSBErrorDomain
                                              code:CSBNotifierErrorContextUnavailable
                                          userInfo:@{
            NSLocalizedDescriptionKey: @"sharedServiceContextForDeveloperDir:error: returned nil",
            @"developerDir": devDir,
        }];
    }
    return ctx;
}

static SimDeviceSet * _Nullable CSBNResolveDeviceSet(NSError **error) {
    if (![CoreSimulatorLoader loadWithError:error]) {
        if (error && *error) {
            NSError *underlying = *error;
            *error = [NSError errorWithDomain:kCSBErrorDomain
                                         code:CSBNotifierErrorLoadFailed
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"CoreSimulator framework load failed",
                NSUnderlyingErrorKey: underlying,
            }];
        }
        return nil;
    }
    SimServiceContext *ctx = CSBNResolveContext(error);
    if (!ctx) return nil;
    NSError *inner = nil;
    SimDeviceSet *set = [ctx defaultDeviceSetWithError:&inner];
    if (!set && error) {
        *error = inner ?: [NSError errorWithDomain:kCSBErrorDomain
                                              code:CSBNotifierErrorDeviceSetFailed
                                          userInfo:@{
            NSLocalizedDescriptionKey: @"defaultDeviceSetWithError: returned nil",
        }];
    }
    return set;
}

#pragma mark - CSBDeviceNotifier

@interface CSBDeviceNotifier ()
@property (nonatomic, strong) SimDeviceSet *deviceSet;
@property (nonatomic) unsigned long long registrationID;
// Atomic: `cancel` writes it from the caller's thread while the registered
// handler reads it on CoreSimulator's delivery queue, and a nonatomic read can
// miss the write entirely. That makes this a reliable gate for a handler that
// has not reached the check yet, not a barrier: handlers already past it run
// to completion, so events can reach the client after `cancel` returned, and
// consumers must tolerate that.
@property (atomic, getter=isCancelled) BOOL cancelled;
@end

@implementation CSBDeviceNotifier

+ (nullable instancetype)defaultNotifierOnQueue:(dispatch_queue_t)queue
                                        handler:(void (^)(CSBNotifierEvent *))handler
                                          error:(NSError **)error {
    if (!queue || !handler) {
        if (error) {
            *error = [NSError errorWithDomain:kCSBErrorDomain
                                         code:CSBNotifierErrorRegisterFailed
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"queue and handler are required",
            }];
        }
        return nil;
    }
    SimDeviceSet *set = CSBNResolveDeviceSet(error);
    if (!set) return nil;

    // Copy the handler so the block lives past this scope. Use a
    // weak reference to the notifier inside the registered block so
    // a never-cancelled handle can still be deallocated; in that
    // case the block is a no-op until the next `unregister`. The
    // `cancelled` check prevents events queued by CoreSimulator
    // from racing past an explicit `cancel`.
    __block __weak CSBDeviceNotifier *weakSelf = nil;
    void (^wrappedHandler)(NSDictionary *) = ^(NSDictionary *info) {
        if (![info isKindOfClass:NSDictionary.class]) return;
        CSBDeviceNotifier *strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf.cancelled) return;
        CSBNotifierEvent *event = CSBNEventFromDict(info);
        handler(event);
    };
    // Cast through `id<SimDeviceNotifier>` because the
    // auto-generated `SimDeviceSet.h` declares the handler
    // parameter as `CDUnknownBlockType` (Hopper output), which the
    // compiler reads as `void (^)(void)`. The protocol header has
    // the correct `void (^)(NSDictionary *)` signature, and the
    // selector dispatch is identical either way, and only the static
    // type at the call site changes.
    id<SimDeviceNotifier> notifier = (id<SimDeviceNotifier>)set;
    unsigned long long regID = [notifier registerNotificationHandlerOnQueue:queue
                                                                    handler:wrappedHandler];
    if (regID == 0) {
        if (error) {
            *error = [NSError errorWithDomain:kCSBErrorDomain
                                         code:CSBNotifierErrorRegisterFailed
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"registerNotificationHandlerOnQueue:handler: returned 0",
            }];
        }
        return nil;
    }

    CSBDeviceNotifier *me = [CSBDeviceNotifier new];
    me.deviceSet = set;
    me.registrationID = regID;
    weakSelf = me;
    return me;
}

- (void)cancel {
    if (self.cancelled) return;
    self.cancelled = YES;
    if (self.deviceSet == nil || self.registrationID == 0) return;
    NSError *unregisterError = nil;
    id<SimDeviceNotifier> notifier = (id<SimDeviceNotifier>)self.deviceSet;
    [notifier unregisterNotificationHandler:self.registrationID error:&unregisterError];
    // We intentionally drop the unregister error: by the time it fails the
    // handle is already cancelled, so `wrappedHandler` returns early for
    // every delivery that has not started yet. That covers a failed
    // unregister; it is not a barrier against a handler already running.
    self.registrationID = 0;
    self.deviceSet = nil;
}

- (void)dealloc {
    [self cancel];
}

@end
