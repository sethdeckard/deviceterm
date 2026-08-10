// SPDX-License-Identifier: GPL-3.0-or-later

#import "SimAccessibility.h"
#import "CoreSimulatorLoader.h"

#import <CoreSimulator/SimServiceContext.h>
#import <CoreSimulator/SimDeviceSet.h>
#import <CoreSimulator/SimDevice.h>
#import <AccessibilityPlatformTranslation/AXPTranslator.h>
#import <AccessibilityPlatformTranslation/AXPTranslationObject.h>
#import <AccessibilityPlatformTranslation/AXPTranslatorRequest.h>
#import <AccessibilityPlatformTranslation/AXPTranslatorResponse.h>
#import <AccessibilityPlatformTranslation/AXPMacPlatformElement.h>

#import <objc/runtime.h>

NSString *const SimAccessibilityErrorDomain = @"CoreSimulatorBridge.SimAccessibility";
static NSString *const kCSBErrorDomain = @"CoreSimulatorBridge.SimAccessibility";

// 5s feels arbitrary but it covers the realistic worst case: an iOS
// process under load taking a few hundred ms to respond, plus headroom.
// Waiting forever hangs the daemon outright if AXP drops a
// completion; an empty response on timeout is preferable.
static const int64_t kCSBAXPRequestTimeoutSeconds = 5;

typedef NS_ENUM(NSInteger, CSBAccessibilityError) {
    CSBAccessibilityErrorCoreSimLoad    = 70,
    CSBAccessibilityErrorAXPLoad        = 71,
    CSBAccessibilityErrorContext        = 72,
    CSBAccessibilityErrorDeviceSet      = 73,
    CSBAccessibilityErrorDeviceNotFound = 74,
    CSBAccessibilityErrorTranslatorMissing       = 75,
    CSBAccessibilityErrorFrontmostNil            = 76,
    CSBAccessibilityErrorMacPlatformElementNil   = 77,
    CSBAccessibilityErrorObjectAtPointNil        = 78,
    CSBAccessibilityErrorDeviceMissingAXSelector = 79,
};

#pragma mark - CSBAccessibilityDelegate (process-wide, token-keyed)

/// One shared instance of this delegate is installed on
/// `AXPTranslator.sharedInstance.bridgeTokenDelegate`. AXP calls into
/// it with a token for every translation request; the delegate looks
/// up the matching `SimDevice` by token from a process-wide
/// dictionary. A per-client delegate cannot work here: the slot
/// lives on a singleton, so constructing a second client would
/// clobber the first client's delegate.
///
/// Thread safety: `_devicesByToken` is guarded by an `NSLock`. AXP can
/// call the delegate from any thread, so every access to the map is
/// serialized through the lock.
@interface CSBAccessibilityDelegate : NSObject <AXPTranslationTokenDelegateHelper>
+ (instancetype)sharedDelegate;
- (void)registerToken:(NSString *)token forDevice:(SimDevice *)device;
- (void)unregisterToken:(NSString *)token;
@end

@implementation CSBAccessibilityDelegate {
    NSMutableDictionary<NSString *, SimDevice *> *_devicesByToken;
    NSLock *_lock;
}

+ (instancetype)sharedDelegate {
    static CSBAccessibilityDelegate *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [CSBAccessibilityDelegate new];
    });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _devicesByToken = [NSMutableDictionary new];
        _lock = [NSLock new];
    }
    return self;
}

- (void)registerToken:(NSString *)token forDevice:(SimDevice *)device {
    [_lock lock];
    _devicesByToken[token] = device;
    [_lock unlock];
}

- (void)unregisterToken:(NSString *)token {
    [_lock lock];
    [_devicesByToken removeObjectForKey:token];
    [_lock unlock];
}

- (nullable SimDevice *)_deviceForToken:(NSString *)token {
    [_lock lock];
    SimDevice *device = _devicesByToken[token];
    [_lock unlock];
    return device;
}

#pragma mark AXPTranslationTokenDelegateHelper

/// AXP calls this to get a callback block for a specific token, then
/// invokes the block to do the sync-over-async request round-trip.
/// We resolve the `SimDevice` from the token **inside** the block
/// (not at block-construction time) so a re-registration of the token
/// to a different device is honored.
- (AXPTranslationCallback)accessibilityTranslationDelegateBridgeCallbackWithToken:(NSString *)token {
    __weak CSBAccessibilityDelegate *weakSelf = self;
    NSString *capturedToken = [token copy];
    return ^AXPTranslatorResponse *(AXPTranslatorRequest *request) {
        Class responseClass = objc_getClass("AXPTranslatorResponse");
        AXPTranslatorResponse *emptyResponse =
            responseClass ? [responseClass emptyResponse] : nil;

        CSBAccessibilityDelegate *strong = weakSelf;
        SimDevice *device = strong ? [strong _deviceForToken:capturedToken] : nil;
        if (!device) return emptyResponse;

        dispatch_queue_t cbQueue = dispatch_queue_create("deviceterm.ax.cb",
                                                         DISPATCH_QUEUE_SERIAL);
        dispatch_group_t group = dispatch_group_create();
        dispatch_group_enter(group);
        __block AXPTranslatorResponse *response = nil;
        [device sendAccessibilityRequestAsync:request
                              completionQueue:cbQueue
                            completionHandler:^(AXPTranslatorResponse *innerResponse) {
            response = innerResponse;
            dispatch_group_leave(group);
        }];

        // Bounded wait: better an empty tree than a hung daemon.
        long timedOut = dispatch_group_wait(group,
            dispatch_time(DISPATCH_TIME_NOW, kCSBAXPRequestTimeoutSeconds * NSEC_PER_SEC));
        if (timedOut != 0) return emptyResponse;
        return response ?: emptyResponse;
    };
}

/// AXP asks the delegate to convert a frame from the iOS-side
/// ("platform") coordinate space into the macOS-side ("system") one.
/// We don't need a transform: the simulator's coordinate space is what
/// we want to render and query against. Skipping this method causes
/// `accessibilityFrame` to crash on first access with `unrecognized
/// selector`.
- (CGRect)accessibilityTranslationConvertPlatformFrameToSystem:(CGRect)rect
                                                      withToken:(NSString *)token {
    return rect;
}

/// AXP walks up the macOS responder chain looking for a "host" element
/// when rendering a translation. We don't have a host, and the iOS-side
/// tree is the whole world we care about, so returning nil is the
/// canonical answer.
- (id)accessibilityTranslationRootParentWithToken:(NSString *)token {
    return nil;
}

@end

#pragma mark - SimAccessibility

@interface SimAccessibility ()
@property (nonatomic, copy, readwrite) NSString *udid;
@property (nonatomic, strong) SimDevice *device;
@property (nonatomic, strong) AXPTranslator *translator;
@property (nonatomic, copy) NSString *token;
@end

@implementation SimAccessibility

#pragma mark Lookup

+ (nullable SimDevice *)_lookupDeviceForUDID:(NSString *)udid error:(NSError **)error {
    Class ctxCls = NSClassFromString(@"SimServiceContext");
    if (!ctxCls) {
        if (error) {
            *error = [NSError errorWithDomain:kCSBErrorDomain
                                         code:CSBAccessibilityErrorContext userInfo:@{
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
                                                  code:CSBAccessibilityErrorContext userInfo:@{
                NSLocalizedDescriptionKey: @"sharedServiceContextForDeveloperDir failed",
            }];
        }
        return nil;
    }
    SimDeviceSet *set = [ctx defaultDeviceSetWithError:&inner];
    if (!set) {
        if (error) {
            *error = inner ?: [NSError errorWithDomain:kCSBErrorDomain
                                                  code:CSBAccessibilityErrorDeviceSet userInfo:@{
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
                                     code:CSBAccessibilityErrorDeviceNotFound
                                 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Device with UDID %@ not found", udid],
        }];
    }
    return nil;
}

+ (nullable instancetype)clientForUDID:(NSString *)udid error:(NSError **)error {
    if (![CoreSimulatorLoader loadWithError:error]) return nil;
    if (![CoreSimulatorLoader loadAccessibilityPlatformTranslationWithError:error]) return nil;

    SimDevice *device = [self _lookupDeviceForUDID:udid error:error];
    if (!device) return nil;

    if (![device respondsToSelector:
          @selector(sendAccessibilityRequestAsync:completionQueue:completionHandler:)]) {
        if (error) {
            *error = [NSError errorWithDomain:kCSBErrorDomain
                                         code:CSBAccessibilityErrorDeviceMissingAXSelector
                                     userInfo:@{
                NSLocalizedDescriptionKey:
                    @"SimDevice has no sendAccessibilityRequestAsync:… (requires Xcode 12+)",
            }];
        }
        return nil;
    }

    Class translatorClass = objc_lookUpClass("AXPTranslator");
    if (!translatorClass) {
        if (error) {
            *error = [NSError errorWithDomain:kCSBErrorDomain
                                         code:CSBAccessibilityErrorTranslatorMissing
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"AXPTranslator class not found after framework load",
            }];
        }
        return nil;
    }

    SimAccessibility *client = [SimAccessibility new];
    client.udid = udid;
    client.device = device;
    client.translator = [translatorClass sharedInstance];
    client.token = [[NSUUID UUID] UUIDString];

    // Install the shared delegate (idempotent, since every call assigns the
    // same singleton instance, so there's no clobber). Register this
    // client's token so AXP callbacks resolve to *its* SimDevice.
    CSBAccessibilityDelegate *shared = [CSBAccessibilityDelegate sharedDelegate];
    client.translator.bridgeTokenDelegate = shared;
    [shared registerToken:client.token forDevice:device];

    return client;
}

- (void)dealloc {
    if (_token) {
        [[CSBAccessibilityDelegate sharedDelegate] unregisterToken:_token];
    }
}

#pragma mark Public API

- (nullable NSDictionary<NSString *, id> *)frontmostTreeWithError:(NSError **)error {
    AXPTranslationObject *translation =
        [self.translator frontmostApplicationWithDisplayId:0
                                       bridgeDelegateToken:self.token];
    if (!translation) {
        if (error) {
            *error = [NSError errorWithDomain:kCSBErrorDomain
                                         code:CSBAccessibilityErrorFrontmostNil
                                     userInfo:@{
                NSLocalizedDescriptionKey:
                    @"frontmostApplication returned nil; is anything running on the device?",
            }];
        }
        return nil;
    }
    translation.bridgeDelegateToken = self.token;
    AXPMacPlatformElement *root = [self.translator macPlatformElementFromTranslation:translation];
    if (!root) {
        if (error) {
            *error = [NSError errorWithDomain:kCSBErrorDomain
                                         code:CSBAccessibilityErrorMacPlatformElementNil
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"macPlatformElementFromTranslation returned nil",
            }];
        }
        return nil;
    }
    root.translation.bridgeDelegateToken = self.token;
    return [self _serializeRecursive:root];
}

- (nullable NSDictionary<NSString *, id> *)elementAtPoint:(CGPoint)point error:(NSError **)error {
    AXPTranslationObject *translation = [self.translator objectAtPoint:point
                                                              displayId:0
                                                    bridgeDelegateToken:self.token];
    if (!translation) {
        if (error) {
            *error = [NSError errorWithDomain:kCSBErrorDomain
                                         code:CSBAccessibilityErrorObjectAtPointNil
                                     userInfo:@{
                NSLocalizedDescriptionKey:
                    @"No element at point: fullscreen modal, out of bounds, or no AX server?",
            }];
        }
        return nil;
    }
    translation.bridgeDelegateToken = self.token;
    AXPMacPlatformElement *element =
        [self.translator macPlatformElementFromTranslation:translation];
    if (!element) {
        if (error) {
            *error = [NSError errorWithDomain:kCSBErrorDomain
                                         code:CSBAccessibilityErrorMacPlatformElementNil
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"macPlatformElementFromTranslation returned nil",
            }];
        }
        return nil;
    }
    element.translation.bridgeDelegateToken = self.token;
    return [self _serializeFlat:element];
}

#pragma mark Serialization

- (NSDictionary<NSString *, id> *)_serializeFlat:(AXPMacPlatformElement *)element {
    element.translation.bridgeDelegateToken = self.token;
    NSMutableDictionary<NSString *, id> *out = [NSMutableDictionary dictionary];
    [self _populate:out from:element];
    return out;
}

- (NSDictionary<NSString *, id> *)_serializeRecursive:(AXPMacPlatformElement *)element {
    element.translation.bridgeDelegateToken = self.token;
    NSMutableDictionary<NSString *, id> *out = [NSMutableDictionary dictionary];
    [self _populate:out from:element];

    NSMutableArray *children = [NSMutableArray array];
    for (AXPMacPlatformElement *child in element.accessibilityChildren) {
        child.translation.bridgeDelegateToken = self.token;
        NSDictionary *childDict = [self _serializeRecursive:child];
        if (childDict) [children addObject:childDict];
    }
    out[@"children"] = children;
    return out;
}

- (void)_populate:(NSMutableDictionary<NSString *, id> *)out
             from:(AXPMacPlatformElement *)element {
    NSString *role = element.accessibilityRole ?: @"";
    if ([role hasPrefix:@"AX"]) role = [role substringFromIndex:2];

    NSString *label = element.accessibilityLabel ?: @"";
    NSString *ident = element.accessibilityIdentifier ?: @"";
    NSString *subrole = element.accessibilitySubrole ?: @"";
    id value = element.accessibilityValue;
    NSRect frame = element.accessibilityFrame;

    out[@"role"] = role;
    if (label.length) out[@"label"] = label;
    if (ident.length) out[@"identifier"] = ident;
    if (subrole.length) out[@"subrole"] = subrole;
    if (value && [NSJSONSerialization isValidJSONObject:@[value]]) {
        out[@"value"] = value;
    } else if (value) {
        out[@"value"] = [value description];
    }
    out[@"frame"] = @{
        @"x": @(frame.origin.x), @"y": @(frame.origin.y),
        @"w": @(frame.size.width), @"h": @(frame.size.height),
    };
}

@end
