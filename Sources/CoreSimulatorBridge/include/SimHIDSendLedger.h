// SPDX-License-Identifier: GPL-3.0-or-later
//
// SimHIDSendLedger: which HID sends a client has handed to SimulatorKit and
// not yet seen complete.
//
// SimulatorKit puts every send on one serial queue per client and sends it with
// no timeout, so a send whose completion is late holds every send behind it.
// `SimHIDClient` waits a bounded time for each completion and gives up after
// that, but giving up cancels nothing. The ledger is what remembers the send
// is still in flight, refuses new input while it is, and tells a caller when
// everything has completed. It holds no SimulatorKit state, so it can be
// exercised without a simulator.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The error domain of every `NSError` `SimHIDClient` and its ledger create.
extern NSErrorDomain const CSBHIDClientErrorDomain;

/// Codes in `CSBHIDClientErrorDomain`.
typedef NS_ENUM(NSInteger, CSBHIDClientError) {
    CSBHIDClientErrorCoreSimLoad        = 40,
    CSBHIDClientErrorSimKitLoad         = 41,
    CSBHIDClientErrorContext            = 42,
    CSBHIDClientErrorDeviceSet          = 43,
    CSBHIDClientErrorDeviceNotFound     = 44,
    CSBHIDClientErrorLegacyClassMissing = 45,
    CSBHIDClientErrorLegacyInitFailed   = 46,
    CSBHIDClientErrorIndigoSymsMissing  = 47,
    CSBHIDClientErrorNilMessage         = 48,
    /// The completion missed the client's wait. The send was not cancelled
    /// and may complete later; delivery is unknown.
    CSBHIDClientErrorSendTimeout        = 49,
    /// An earlier send has not completed, so this one was not sent.
    CSBHIDClientErrorTransportStalled   = 50,
};

/// Ticket-based bookkeeping for one client's sends. Thread-safe: every method
/// may be called from any thread.
@interface SimHIDSendLedger : NSObject

/// Sends admitted and not yet completed, including ones whose waiter gave up.
@property (nonatomic, readonly) NSUInteger outstandingSendCount;

/// Admit one send, writing its ticket to `ticket`.
///
/// Refuses with `CSBHIDClientErrorTransportStalled` when any earlier send is
/// still outstanding, unless `isRelease` is YES. A release still goes out:
/// queued behind the stalled send it lifts what is down once that send
/// completes, and refusing it would leave the contact held.
- (BOOL)admitSendAsRelease:(BOOL)isRelease
                    ticket:(uint64_t *)ticket
                     error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(admitSend(asRelease:ticket:));

/// The send's waiter stopped waiting. Its completion, when it comes, is
/// reported to the next settle handler rather than to that waiter.
///
/// Returns NO, and changes nothing, when the ticket has already completed:
/// its completion ran between the waiter's deadline and this call, so the
/// waiter still owns that outcome and has to collect it itself.
- (BOOL)abandonWaitForTicket:(uint64_t)ticket
    NS_SWIFT_NAME(abandonWait(forTicket:));

/// The send completed, with SimulatorKit's error if it reported one.
- (void)completeTicket:(uint64_t)ticket
                 error:(nullable NSError *)error
    NS_SWIFT_NAME(complete(ticket:error:));

/// Call `handler` on `queue` once no send is outstanding, immediately if none
/// is now. Reports the first unreported error a send returned after its waiter
/// gave up, or nil if none remains. Reporting consumes the error; handlers
/// waiting together receive the same result.
- (void)whenSettledOnQueue:(dispatch_queue_t)queue
                   handler:(void (^)(NSError * _Nullable lateError))handler
    NS_SWIFT_NAME(whenSettled(on:handler:));

/// Call `handler` on `queue` once no send is outstanding, immediately if none
/// is now. Unlike `whenSettledOnQueue:handler:` it reports no error and
/// consumes none, so watching for a drain can't take a failure from the caller
/// that needs it.
- (void)whenDrainedOnQueue:(dispatch_queue_t)queue
                   handler:(void (^)(void))handler
    NS_SWIFT_NAME(whenDrained(on:handler:));

@end

NS_ASSUME_NONNULL_END
