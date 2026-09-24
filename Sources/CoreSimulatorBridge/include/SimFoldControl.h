// SPDX-License-Identifier: GPL-3.0-or-later
//
// SimFoldControl: run a guest-side program on a booted simulator.
//
// The hinge of a foldable simulator can only be moved from inside the guest,
// by a program that links the guest's IOKit and dispatches the event its
// virtualized hinge driver listens for. That program is therefore an
// arm64-iphonesimulator binary, and this is what runs it: CoreSimulator's own
// spawn, so the daemon neither shells out to `simctl` nor reimplements it.
//
// The caller supplies the binary. Compiling and caching it is the daemon's
// job (`FoldHelperBuilder`); keeping it out of here leaves this file about
// the private API and nothing else.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs a program inside a booted simulator, within a bounded wait.
@interface SimFoldControl : NSObject

/// Spawn `binaryPath` on the device with `arguments`, wait up to ten seconds
/// for it to exit, and report its exit status in `exitStatus`.
///
/// A program that outlives that wait is **not** terminated: this returns NO
/// and leaves it running. The helper it exists to run dispatches one event
/// and exits, so the bound is there to stop a wedged guest holding the
/// caller's queue, not to police runtime.
///
/// The binary must be built for the simulator: a macOS Mach-O is rejected by
/// the guest's loader, which surfaces as a non-zero status rather than an
/// error here. Output is discarded; the exit status is the result.
///
/// Returns NO when the device is not booted, when the spawn itself fails, or
/// when the program could not be started. A program that ran and failed
/// returns YES with a non-zero `exitStatus`, because it did run.
+ (BOOL)runBinaryAtPath:(NSString *)binaryPath
               onDevice:(NSString *)udid
              arguments:(NSArray<NSString *> *)arguments
             exitStatus:(int *)exitStatus
                  error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(run(binaryAtPath:onDevice:arguments:exitStatus:));

@end

NS_ASSUME_NONNULL_END
