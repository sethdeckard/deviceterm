// SPDX-License-Identifier: GPL-3.0-or-later

#import "SimDeviceHandle.h"
#import "CoreSimulatorLoader.h"

#import <CoreSimulator/SimServiceContext.h>
#import <CoreSimulator/SimDeviceSet.h>
#import <CoreSimulator/SimDevice.h>
#import <CoreSimulator/SimRuntime.h>
#import <CoreSimulator/SimDeviceType.h>

static NSString *const kCSBErrorDomain = @"CoreSimulatorBridge.SimDeviceHandle";

// Error codes within this module's domain. Stable values so callers can
// switch on them.
typedef NS_ENUM(NSInteger, CSBDeviceHandleError) {
    CSBDeviceHandleErrorLoadFailed         = 10,
    CSBDeviceHandleErrorContextUnavailable = 11,
    CSBDeviceHandleErrorDeviceSetFailed    = 12,
    CSBDeviceHandleErrorNoBootedDevice     = 13,
    CSBDeviceHandleErrorMultipleBooted     = 14,
    CSBDeviceHandleErrorNotFound           = 15,
};

#pragma mark - CSBDeviceInfo

// Private mutator interface so the .m can populate readonly properties.
@interface CSBDeviceInfo ()
@property (nonatomic, copy, readwrite) NSString *udid;
@property (nonatomic, copy, readwrite) NSString *name;
@property (nonatomic, copy, readwrite) NSString *runtimeIdentifier;
@property (nonatomic, copy, readwrite) NSString *deviceTypeIdentifier;
@property (nonatomic, copy, readwrite) NSString *deviceTypeName;
@property (nonatomic, readwrite) CSBSimState state;
@end

@implementation CSBDeviceInfo
@end

#pragma mark - SimDeviceHandle

@interface SimDeviceHandle ()
@property (nonatomic, strong) SimDevice *device;
@end

@implementation SimDeviceHandle

#pragma mark Internal helpers

+ (nullable SimServiceContext *)_serviceContextWithError:(NSError **)error {
    Class ctxCls = NSClassFromString(@"SimServiceContext");
    if (!ctxCls) {
        if (error) {
            *error = [NSError errorWithDomain:kCSBErrorDomain
                                         code:CSBDeviceHandleErrorContextUnavailable
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
                                              code:CSBDeviceHandleErrorContextUnavailable
                                          userInfo:@{
            NSLocalizedDescriptionKey: @"sharedServiceContextForDeveloperDir:error: returned nil",
            @"developerDir": devDir,
        }];
    }
    return ctx;
}

+ (nullable SimDeviceSet *)_defaultDeviceSetWithError:(NSError **)error {
    if (![CoreSimulatorLoader loadWithError:error]) {
        // Re-wrap to anchor the error to this module's domain.
        if (error && *error) {
            NSError *underlying = *error;
            *error = [NSError errorWithDomain:kCSBErrorDomain
                                         code:CSBDeviceHandleErrorLoadFailed
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"CoreSimulator framework load failed",
                NSUnderlyingErrorKey: underlying,
            }];
        }
        return nil;
    }
    SimServiceContext *ctx = [self _serviceContextWithError:error];
    if (!ctx) return nil;
    NSError *inner = nil;
    SimDeviceSet *set = [ctx defaultDeviceSetWithError:&inner];
    if (!set && error) {
        *error = inner ?: [NSError errorWithDomain:kCSBErrorDomain
                                              code:CSBDeviceHandleErrorDeviceSetFailed
                                          userInfo:@{
            NSLocalizedDescriptionKey: @"defaultDeviceSetWithError: returned nil",
        }];
    }
    return set;
}

/// Map CoreSimulator's `unsigned long long` state raw to our enum.
///
/// Empirically confirmed values (macOS 26.4 / Xcode 26.4), aligned with
/// FBSimulatorControl's `FBSimulatorState`:
///
///   0 = Creating, 1 = Shutdown, 2 = Booting, 3 = Booted, 4 = ShuttingDown
///
/// Any out-of-range value normalizes to `CSBSimStateUnknown` so we never
/// silently misclassify a future state Apple introduces.
+ (CSBSimState)_normalizeState:(unsigned long long)raw {
    if (raw <= 4) return (CSBSimState)raw;
    return CSBSimStateUnknown;
}

+ (CSBDeviceInfo *)_infoFor:(SimDevice *)dev {
    CSBDeviceInfo *info = [CSBDeviceInfo new];
    info.udid = dev.UDID.UUIDString ?: @"";
    info.name = dev.name ?: @"";
    info.runtimeIdentifier = dev.runtime.identifier ?: dev.runtimeIdentifier ?: @"";
    info.deviceTypeIdentifier = dev.deviceType.identifier ?: dev.deviceTypeIdentifier ?: @"";
    info.deviceTypeName = dev.deviceType.name ?: @"";
    info.state = [self _normalizeState:dev.state];
    return info;
}

#pragma mark Public enumeration

+ (NSArray<CSBDeviceInfo *> *)allDevicesWithError:(NSError **)error {
    SimDeviceSet *set = [self _defaultDeviceSetWithError:error];
    if (!set) return nil;
    NSArray<SimDevice *> *devices = set.devices;
    NSMutableArray<CSBDeviceInfo *> *out = [NSMutableArray arrayWithCapacity:devices.count];
    for (SimDevice *dev in devices) {
        [out addObject:[self _infoFor:dev]];
    }
    return [out copy];
}

+ (CSBDeviceInfo *)singleBootedDeviceWithError:(NSError **)error {
    NSArray<CSBDeviceInfo *> *all = [self allDevicesWithError:error];
    if (!all) return nil;

    NSMutableArray<CSBDeviceInfo *> *booted = [NSMutableArray array];
    for (CSBDeviceInfo *info in all) {
        if (info.state == CSBSimStateBooted) [booted addObject:info];
    }
    if (booted.count == 1) return booted.firstObject;
    if (error) {
        CSBDeviceHandleError code = booted.count == 0
            ? CSBDeviceHandleErrorNoBootedDevice
            : CSBDeviceHandleErrorMultipleBooted;
        NSString *message = booted.count == 0
            ? @"No booted device"
            : [NSString stringWithFormat:@"%lu booted devices; expected exactly 1",
               (unsigned long)booted.count];
        *error = [NSError errorWithDomain:kCSBErrorDomain code:code userInfo:@{
            NSLocalizedDescriptionKey: message,
        }];
    }
    return nil;
}

#pragma mark Public lookup

+ (instancetype)handleForUDID:(NSString *)udid error:(NSError **)error {
    SimDeviceSet *set = [self _defaultDeviceSetWithError:error];
    if (!set) return nil;

    NSString *needle = udid.lowercaseString;
    for (SimDevice *dev in set.devices) {
        if ([dev.UDID.UUIDString.lowercaseString isEqualToString:needle]) {
            SimDeviceHandle *handle = [SimDeviceHandle new];
            handle.device = dev;
            return handle;
        }
    }
    if (error) {
        *error = [NSError errorWithDomain:kCSBErrorDomain
                                     code:CSBDeviceHandleErrorNotFound
                                 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Device with UDID %@ not found", udid],
        }];
    }
    return nil;
}

#pragma mark Public instance

- (NSString *)udid {
    return self.device.UDID.UUIDString ?: @"";
}

- (NSString *)name {
    return self.device.name ?: @"";
}

- (NSString *)runtimeIdentifier {
    return self.device.runtime.identifier ?: self.device.runtimeIdentifier ?: @"";
}

- (NSString *)deviceTypeIdentifier {
    return self.device.deviceType.identifier ?: self.device.deviceTypeIdentifier ?: @"";
}

- (NSString *)deviceTypeName {
    return self.device.deviceType.name ?: @"";
}

- (CSBSimState)state {
    return [SimDeviceHandle _normalizeState:self.device.state];
}

- (BOOL)bootWithError:(NSError **)error {
    NSError *inner = nil;
    BOOL ok = [self.device bootWithOptions:@{} error:&inner];
    if (!ok && error) *error = inner;
    return ok;
}

- (BOOL)shutdownWithError:(NSError **)error {
    NSError *inner = nil;
    BOOL ok = [self.device shutdownWithError:&inner];
    if (!ok && error) *error = inner;
    return ok;
}

@end
