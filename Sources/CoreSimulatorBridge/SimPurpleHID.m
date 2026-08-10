// SPDX-License-Identifier: GPL-3.0-or-later

#import "SimPurpleHID.h"
#import "CoreSimulatorLoader.h"

#import <CoreSimulator/SimServiceContext.h>
#import <CoreSimulator/SimDeviceSet.h>
#import <CoreSimulator/SimDevice.h>
#import <SimulatorApp/GSEvent.h>

#import <mach/mach.h>
#import <objc/runtime.h>

static NSString *const kCSBErrorDomain = @"CoreSimulatorBridge.SimPurpleHID";

typedef NS_ENUM(NSInteger, CSBPurpleHIDError) {
    CSBPurpleHIDErrorLoadFailed       = 60,
    CSBPurpleHIDErrorContext          = 61,
    CSBPurpleHIDErrorDeviceSet        = 62,
    CSBPurpleHIDErrorDeviceNotFound   = 63,
    CSBPurpleHIDErrorPortLookup       = 64,
    CSBPurpleHIDErrorMachSendFailed   = 65,
};

@interface SimPurpleHID ()
@property (nonatomic, copy, readwrite) NSString *udid;
@property (nonatomic, strong) SimDevice *device;
@end

@implementation SimPurpleHID

#pragma mark Lookup

+ (nullable SimDevice *)_lookupDeviceForUDID:(NSString *)udid error:(NSError **)error {
    Class ctxCls = NSClassFromString(@"SimServiceContext");
    if (!ctxCls) {
        if (error) {
            *error = [NSError errorWithDomain:kCSBErrorDomain
                                         code:CSBPurpleHIDErrorContext userInfo:@{
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
                                                  code:CSBPurpleHIDErrorContext userInfo:@{
                NSLocalizedDescriptionKey: @"sharedServiceContextForDeveloperDir failed",
            }];
        }
        return nil;
    }
    SimDeviceSet *set = [ctx defaultDeviceSetWithError:&inner];
    if (!set) {
        if (error) {
            *error = inner ?: [NSError errorWithDomain:kCSBErrorDomain
                                                  code:CSBPurpleHIDErrorDeviceSet userInfo:@{
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
                                     code:CSBPurpleHIDErrorDeviceNotFound
                                 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Device with UDID %@ not found", udid],
        }];
    }
    return nil;
}

+ (nullable instancetype)clientForUDID:(NSString *)udid error:(NSError **)error {
    if (![CoreSimulatorLoader loadWithError:error]) {
        if (error && *error) {
            NSError *underlying = *error;
            *error = [NSError errorWithDomain:kCSBErrorDomain
                                         code:CSBPurpleHIDErrorLoadFailed
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"CoreSimulator framework load failed",
                NSUnderlyingErrorKey: underlying,
            }];
        }
        return nil;
    }
    SimDevice *device = [self _lookupDeviceForUDID:udid error:error];
    if (!device) return nil;

    SimPurpleHID *client = [SimPurpleHID new];
    client.udid = udid;
    client.device = device;
    return client;
}

#pragma mark Rotate (reverse-engineered wire format, preserve)

/// Send a GSEvent device-orientation message to the simulator's
/// PurpleWorkspacePort.
///
/// **Wire format** (reverse-engineered from Simulator.app and idb's
/// `FBSimulatorPurpleHID`; do not "simplify" the layout):
///
///     0x00..0x17 mach_msg_header_t
///     0x18..0x1b GSEvent type | GSEventHostFlag
///     0x48..0x4b record_info_size (= 4 for orientation)
///     0x4c..0x4f orientation value (1..4, matches UIDeviceOrientation)
///
/// Total buffer is 112 bytes (zero-padded). `msgh_size` is **108**,
/// the size Simulator.app's own send sequence uses, and deliberately
/// *not* the buffer size. The bytes beyond `msgh_size` exist in the
/// allocation but aren't part of the message kernel transmits.
- (BOOL)rotateTo:(CSBDeviceOrientation)orientation error:(NSError **)error {
    NSError *inner = nil;
    mach_port_t purplePort = [self.device lookup:@"PurpleWorkspacePort" error:&inner];
    if (purplePort == 0) {
        if (error) {
            *error = inner ?: [NSError errorWithDomain:kCSBErrorDomain
                                                  code:CSBPurpleHIDErrorPortLookup
                                              userInfo:@{
                NSLocalizedDescriptionKey: @"PurpleWorkspacePort not found in simulator bootstrap namespace",
            }];
        }
        return NO;
    }

    uint8_t buf[112];
    memset(buf, 0, sizeof(buf));

    mach_msg_header_t *header = (mach_msg_header_t *)buf;
    header->msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
    header->msgh_size = 108;
    header->msgh_remote_port = purplePort;
    header->msgh_local_port = MACH_PORT_NULL;
    header->msgh_id = GSEventMachMessageID;

    uint32_t *gsEventType = (uint32_t *)(buf + 0x18);
    *gsEventType = GSEventTypeDeviceOrientationChanged | GSEventHostFlag;

    uint32_t *dataSize = (uint32_t *)(buf + 0x48);
    *dataSize = 4;

    uint32_t *orientationField = (uint32_t *)(buf + 0x4C);
    *orientationField = (uint32_t)orientation;

    kern_return_t kr = mach_msg_send(header);

    // `lookup:error:` returned a fresh send right into our task's port
    // namespace; `MACH_MSG_TYPE_COPY_SEND` keeps that right after the
    // message is delivered. Release it unconditionally. Without this,
    // every rotation leaks a Mach port right and a long-running daemon
    // eventually exhausts its namespace.
    (void)mach_port_deallocate(mach_task_self(), purplePort);

    if (kr != KERN_SUCCESS) {
        if (error) {
            *error = [NSError errorWithDomain:kCSBErrorDomain
                                         code:CSBPurpleHIDErrorMachSendFailed
                                     userInfo:@{
                NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"mach_msg_send to PurpleWorkspacePort failed: %d", kr],
            }];
        }
        return NO;
    }
    return YES;
}

@end
