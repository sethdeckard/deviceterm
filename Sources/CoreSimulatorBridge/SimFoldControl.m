// SPDX-License-Identifier: GPL-3.0-or-later

#import "SimFoldControl.h"
#import "CoreSimulatorLoader.h"

#import <CoreSimulator/SimServiceContext.h>
#import <CoreSimulator/SimDeviceSet.h>
#import <CoreSimulator/SimDevice.h>

#import <fcntl.h>
#import <unistd.h>

static NSString *const kCSBErrorDomain = @"CoreSimulatorBridge.SimFoldControl";

typedef NS_ENUM(NSInteger, CSBFoldControlError) {
    CSBFoldControlErrorLoadFailed      = 90,
    CSBFoldControlErrorContext         = 91,
    CSBFoldControlErrorDeviceSet       = 92,
    CSBFoldControlErrorDeviceNotFound  = 93,
    CSBFoldControlErrorDeviceNotBooted = 94,
    CSBFoldControlErrorSpawnFailed     = 95,
    CSBFoldControlErrorSpawnTimedOut   = 96,
};

/// A spawned guest program is expected to dispatch one event and exit. This
/// bounds the wait so a helper that hangs cannot hold the caller's queue
/// forever; the fold is reported as failed instead.
static const int64_t kCSBFoldSpawnTimeoutSeconds = 10;

@implementation SimFoldControl

+ (nullable SimDevice *)_bootedDeviceForUDID:(NSString *)udid error:(NSError **)error {
    Class ctxCls = NSClassFromString(@"SimServiceContext");
    if (!ctxCls) {
        if (error) {
            *error = [NSError errorWithDomain:kCSBErrorDomain
                                         code:CSBFoldControlErrorContext
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"SimServiceContext class not found",
            }];
        }
        return nil;
    }
    NSString *devDir = [CoreSimulatorLoader resolveDeveloperDir];
    NSError *inner = nil;
    SimServiceContext *ctx = [ctxCls sharedServiceContextForDeveloperDir:devDir error:&inner];
    if (!ctx) {
        if (error) *error = inner;
        return nil;
    }
    SimDeviceSet *set = [ctx defaultDeviceSetWithError:&inner];
    if (!set) {
        if (error) *error = inner;
        return nil;
    }
    NSString *needle = udid.lowercaseString;
    for (SimDevice *device in set.devices) {
        if (![device.UDID.UUIDString.lowercaseString isEqualToString:needle]) continue;
        // `spawn` on a shut-down device fails deep inside CoreSimulator with
        // an opaque error, so the state is checked here where the answer can
        // say what is actually wrong.
        if (device.state != 3) {
            if (error) {
                *error = [NSError errorWithDomain:kCSBErrorDomain
                                             code:CSBFoldControlErrorDeviceNotBooted
                                         userInfo:@{
                    NSLocalizedDescriptionKey: @"device is not booted",
                }];
            }
            return nil;
        }
        return device;
    }
    if (error) {
        *error = [NSError errorWithDomain:kCSBErrorDomain
                                     code:CSBFoldControlErrorDeviceNotFound
                                 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:
                @"Device with UDID %@ not found", udid],
        }];
    }
    return nil;
}

+ (BOOL)runBinaryAtPath:(NSString *)binaryPath
               onDevice:(NSString *)udid
              arguments:(NSArray<NSString *> *)arguments
             exitStatus:(int *)exitStatus
                  error:(NSError **)error {
    if (![CoreSimulatorLoader loadWithError:error]) {
        if (error && *error) {
            *error = [NSError errorWithDomain:kCSBErrorDomain
                                         code:CSBFoldControlErrorLoadFailed
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"CoreSimulator framework load failed",
                NSUnderlyingErrorKey: *error,
            }];
        }
        return NO;
    }
    SimDevice *device = [self _bootedDeviceForUDID:udid error:error];
    if (!device) return NO;

    // argv[0] is the program itself, the convention the guest loader expects.
    NSMutableArray<NSString *> *argv = [NSMutableArray arrayWithObject:binaryPath];
    [argv addObjectsFromArray:arguments];
    // Output goes nowhere: the helper reports through its exit status, and
    // inheriting the daemon's descriptors into the guest would outlive the
    // call.
    //
    // These are **file descriptors**, not paths. CoreSimulator forwards them
    // to `spawnInSession:…standardOutput:standardError:…` as numbers, so a
    // string here is read as a descriptor and aborts the process rather than
    // failing the call.
    int devNull = open("/dev/null", O_WRONLY);
    NSMutableDictionary *options = [@{@"arguments": argv} mutableCopy];
    if (devNull >= 0) {
        options[@"stdout"] = @(devNull);
        options[@"stderr"] = @(devNull);
    }
    // Closing is the spawn's job, not the caller's. A wait that gives up
    // returns while the spawn is still outstanding, and closing then would
    // point CoreSimulator's write at whatever the daemon opens next; leaving
    // it to the caller instead leaks one descriptor per timeout. So both
    // handlers close it, whichever of them arrives, however late. `queue` is
    // serial and both run on it, so the flag needs no other guard.
    __block BOOL closed = NO;
    void (^closeDevNull)(void) = ^{
        if (devNull >= 0 && !closed) {
            closed = YES;
            close(devNull);
        }
    };

    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    __block int status = -1;
    __block NSError *launchError = nil;
    dispatch_queue_t queue = dispatch_queue_create("com.deviceterm.csb.fold-spawn",
                                                   DISPATCH_QUEUE_SERIAL);

    // The async form rather than `spawnWithPath:`, because the vendored
    // header types that one's termination handler as taking no arguments
    // while this one declares the real `void (^)(int)`. Same spawn either
    // way; only this signature can report the exit status without guessing
    // at a block shape.
    //
    // Exactly one of the two handlers ends the wait. A launch that fails
    // never runs the program, so its termination handler never fires and the
    // completion handler is what releases the caller.
    @try {
        [device spawnAsyncWithPath:binaryPath
                           options:options
                  terminationQueue:queue
                terminationHandler:^(int terminationStatus) {
                    status = terminationStatus;
                    closeDevNull();
                    dispatch_semaphore_signal(finished);
                }
                   completionQueue:queue
                 completionHandler:^(NSError *completionError, pid_t pid) {
                    if (completionError) {
                        launchError = completionError;
                        closeDevNull();
                        dispatch_semaphore_signal(finished);
                    }
                }];
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:kCSBErrorDomain
                                         code:CSBFoldControlErrorSpawnFailed
                                     userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:
                    @"spawn threw: %@", exception.reason ?: @"(no reason)"],
            }];
        }
        // Nothing was spawned, so no handler will ever run and this is the
        // only place that can close it.
        if (devNull >= 0) close(devNull);
        return NO;
    }

    if (dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW,
            kCSBFoldSpawnTimeoutSeconds * NSEC_PER_SEC)) != 0) {
        if (error) {
            *error = [NSError errorWithDomain:kCSBErrorDomain
                                         code:CSBFoldControlErrorSpawnTimedOut
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"the guest program did not exit in time",
            }];
        }
        // Left to the handlers: the spawn is still outstanding, and one of
        // them closes it whenever it lands.
        return NO;
    }
    if (launchError) {
        if (error) *error = launchError;
        return NO;
    }
    if (exitStatus) *exitStatus = status;
    return YES;
}

@end
