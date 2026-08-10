// SPDX-License-Identifier: GPL-3.0-or-later

#import "SimLocation.h"
#import "CoreSimulatorLoader.h"

#import <CoreSimulator/SimServiceContext.h>
#import <CoreSimulator/SimDeviceSet.h>
#import <CoreSimulator/SimDevice.h>

static NSString *const kCSBErrorDomain = @"CoreSimulatorBridge.SimLocation";

typedef NS_ENUM(NSInteger, CSBLocationError) {
    CSBLocationErrorLoadFailed         = 80,
    CSBLocationErrorContext            = 81,
    CSBLocationErrorDeviceSet          = 82,
    CSBLocationErrorDeviceNotFound     = 83,
    CSBLocationErrorSelectorUnavailable = 84,
    CSBLocationErrorCallFailed         = 85,
    CSBLocationErrorBadWaypoints       = 86,
};

@interface SimLocation ()
@property (nonatomic, copy, readwrite) NSString *udid;
@property (nonatomic, strong) SimDevice *device;
@end

@implementation SimLocation

#pragma mark Lookup

+ (nullable SimDevice *)_lookupDeviceForUDID:(NSString *)udid error:(NSError **)error {
    Class ctxCls = NSClassFromString(@"SimServiceContext");
    if (!ctxCls) {
        if (error) {
            *error = [NSError errorWithDomain:kCSBErrorDomain
                                         code:CSBLocationErrorContext userInfo:@{
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
                                                  code:CSBLocationErrorContext userInfo:@{
                NSLocalizedDescriptionKey: @"sharedServiceContextForDeveloperDir failed",
            }];
        }
        return nil;
    }
    SimDeviceSet *set = [ctx defaultDeviceSetWithError:&inner];
    if (!set) {
        if (error) {
            *error = inner ?: [NSError errorWithDomain:kCSBErrorDomain
                                                  code:CSBLocationErrorDeviceSet userInfo:@{
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
                                     code:CSBLocationErrorDeviceNotFound
                                 userInfo:@{
            NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"Device with UDID %@ not found", udid],
        }];
    }
    return nil;
}

+ (nullable instancetype)clientForUDID:(NSString *)udid error:(NSError **)error {
    if (![CoreSimulatorLoader loadWithError:error]) {
        if (error && *error) {
            NSError *underlying = *error;
            *error = [NSError errorWithDomain:kCSBErrorDomain
                                         code:CSBLocationErrorLoadFailed
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"CoreSimulator framework load failed",
                NSUnderlyingErrorKey: underlying,
            }];
        }
        return nil;
    }
    SimDevice *device = [self _lookupDeviceForUDID:udid error:error];
    if (!device) return nil;

    SimLocation *client = [SimLocation new];
    client.udid = udid;
    client.device = device;
    return client;
}

#pragma mark Selector guarding

/// Guard selector dispatch for callers that have not run the
/// compatibility probe, returning a typed error instead of an
/// unrecognized-selector exception.
- (BOOL)_requireSelector:(SEL)sel error:(NSError **)error {
    if ([self.device respondsToSelector:sel]) return YES;
    if (error) {
        *error = [NSError errorWithDomain:kCSBErrorDomain
                                     code:CSBLocationErrorSelectorUnavailable
                                 userInfo:@{
            NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"SimDevice does not respond to %@",
                                           NSStringFromSelector(sel)],
        }];
    }
    return NO;
}

/// Normalize a failed `BOOL`-returning call into a typed error when the
/// callee left `*error` nil (several of these selectors do).
- (BOOL)_finishCall:(BOOL)ok
              inner:(NSError *)inner
        description:(NSString *)description
              error:(NSError **)error {
    if (ok) return YES;
    if (error) {
        *error = inner ?: [NSError errorWithDomain:kCSBErrorDomain
                                              code:CSBLocationErrorCallFailed
                                          userInfo:@{
            NSLocalizedDescriptionKey: description,
        }];
    }
    return NO;
}

#pragma mark Scenarios

- (nullable NSArray<NSString *> *)availableScenariosWithError:(NSError **)error {
    SEL sel = @selector(availableLocationScenarios);
    if (![self _requireSelector:sel error:error]) return nil;

    id raw = [self.device availableLocationScenarios];

    // Live-verified shape (Xcode 26.5 / iOS 26): an `NSArray` of
    // `NSDictionary`. Each dictionary carries `name` and `localizedName`.
    // Both are `NSString` values, identical for the four built-ins on an
    // English host. `setLocationScenario:` expects `name`, so this
    // wrapper vends `name` only; `as-tested.md` records `localizedName`
    // as part of the observed private-API shape.
    //
    // The selector is still declared `- (id)`, so the string-array and
    // dictionary-keyed shapes are kept as fallbacks rather than assuming
    // the observed one is guaranteed.
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    if ([raw isKindOfClass:[NSArray class]]) {
        for (id element in (NSArray *)raw) {
            if ([element isKindOfClass:[NSString class]]) {
                [names addObject:(NSString *)element];
            } else if ([element isKindOfClass:[NSDictionary class]]) {
                id name = ((NSDictionary *)element)[@"name"]
                    ?: ((NSDictionary *)element)[@"localizedName"];
                if ([name isKindOfClass:[NSString class]]) {
                    [names addObject:(NSString *)name];
                }
            }
        }
    } else if ([raw isKindOfClass:[NSDictionary class]]) {
        for (id key in ((NSDictionary *)raw).allKeys) {
            if ([key isKindOfClass:[NSString class]]) {
                [names addObject:(NSString *)key];
            }
        }
        [names sortUsingSelector:@selector(localizedStandardCompare:)];
    }
    return names;
}

#pragma mark Mutation

- (BOOL)setLatitude:(double)latitude longitude:(double)longitude error:(NSError **)error {
    SEL sel = @selector(setLocationWithLatitude:andLongitude:error:);
    if (![self _requireSelector:sel error:error]) return NO;

    NSError *inner = nil;
    BOOL ok = [self.device setLocationWithLatitude:latitude
                                      andLongitude:longitude
                                             error:&inner];
    return [self _finishCall:ok
                       inner:inner
                 description:[NSString stringWithFormat:
                                 @"setLocationWithLatitude:%f andLongitude:%f failed",
                                 latitude, longitude]
                       error:error];
}

- (BOOL)setScenario:(NSString *)scenario error:(NSError **)error {
    SEL sel = @selector(setLocationScenario:error:);
    if (![self _requireSelector:sel error:error]) return NO;

    NSError *inner = nil;
    BOOL ok = [self.device setLocationScenario:scenario error:&inner];
    return [self _finishCall:ok
                       inner:inner
                 description:[NSString stringWithFormat:
                                 @"setLocationScenario:%@ failed", scenario]
                       error:error];
}

- (BOOL)clearWithError:(NSError **)error {
    SEL sel = @selector(clearSimulatedLocationWithError:);
    if (![self _requireSelector:sel error:error]) return NO;

    NSError *inner = nil;
    BOOL ok = [self.device clearSimulatedLocationWithError:&inner];
    return [self _finishCall:ok
                       inner:inner
                 description:@"clearSimulatedLocationWithError failed"
                       error:error];
}

#pragma mark Routes

/// Reject a waypoint array the route selectors would accept and then
/// misread. They take a bare `NSArray` with nothing behind it: an odd
/// count leaves the final latitude with no longitude to pair with, and
/// a non-`NSNumber` element reaches a secure-coding archiver inside
/// Apple's code. `simctl` performs the same arity check itself ("Must
/// specify at least two waypoints"), which is the tell that the selector
/// does not.
- (BOOL)_requireWaypoints:(NSArray<NSNumber *> *)waypoints error:(NSError **)error {
    NSString *problem = nil;
    if (waypoints.count < 4) {
        problem = @"a route needs at least two waypoints (four coordinate values)";
    } else if (waypoints.count % 2 != 0) {
        problem = @"waypoints must hold a longitude for every latitude";
    } else {
        for (id element in waypoints) {
            if (![element isKindOfClass:[NSNumber class]]) {
                problem = @"waypoints must contain only NSNumber values";
                break;
            }
        }
    }
    if (!problem) return YES;
    if (error) {
        *error = [NSError errorWithDomain:kCSBErrorDomain
                                     code:CSBLocationErrorBadWaypoints
                                 userInfo:@{ NSLocalizedDescriptionKey: problem }];
    }
    return NO;
}

- (BOOL)startRouteWithDistance:(double)meters
                         speed:(double)speed
                     waypoints:(NSArray<NSNumber *> *)waypoints
                         error:(NSError **)error {
    SEL sel = @selector(startLocationSimulationWithDistance:speed:waypoints:error:);
    if (![self _requireSelector:sel error:error]) return NO;
    if (![self _requireWaypoints:waypoints error:error]) return NO;

    NSError *inner = nil;
    BOOL ok = [self.device startLocationSimulationWithDistance:meters
                                                         speed:speed
                                                     waypoints:waypoints
                                                         error:&inner];
    return [self _finishCall:ok
                       inner:inner
                 description:[NSString stringWithFormat:
                                 @"startLocationSimulationWithDistance:%f speed:%f "
                                 @"(%lu waypoints) failed",
                                 meters, speed, (unsigned long)(waypoints.count / 2)]
                       error:error];
}

- (BOOL)startRouteWithInterval:(double)seconds
                         speed:(double)speed
                     waypoints:(NSArray<NSNumber *> *)waypoints
                         error:(NSError **)error {
    SEL sel = @selector(startLocationSimulationWithInterval:speed:waypoints:error:);
    if (![self _requireSelector:sel error:error]) return NO;
    if (![self _requireWaypoints:waypoints error:error]) return NO;

    NSError *inner = nil;
    BOOL ok = [self.device startLocationSimulationWithInterval:seconds
                                                         speed:speed
                                                     waypoints:waypoints
                                                         error:&inner];
    return [self _finishCall:ok
                       inner:inner
                 description:[NSString stringWithFormat:
                                 @"startLocationSimulationWithInterval:%f speed:%f "
                                 @"(%lu waypoints) failed",
                                 seconds, speed, (unsigned long)(waypoints.count / 2)]
                       error:error];
}

@end
