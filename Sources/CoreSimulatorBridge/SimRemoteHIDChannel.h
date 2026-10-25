// SPDX-License-Identifier: GPL-3.0-or-later

#import <Foundation/Foundation.h>
#import <xpc/xpc.h>

@class SimDevice;

NS_ASSUME_NONNULL_BEGIN

/// One connection from this process to a service of a simulator's HID daemon,
/// made the way CoreDevice makes it: the service's Mach port from the
/// simulator's bootstrap, wrapped as an XPC endpoint, opened as a
/// host-to-simulator connection. Without that last step the daemon drops the
/// peer as soon as it activates.
///
/// A lost connection is not reopened in place. The daemon ties its session to
/// the connection, so a replacement needs its own opening request; the owner
/// opens a new channel instead. Thread-safe.
@interface SimRemoteHIDChannel : NSObject

/// Open a connection to `service` in `device`'s bootstrap. Nil when the
/// service or the SPI that reaches it is unavailable.
+ (nullable instancetype)channelForDevice:(SimDevice *)device
                                  service:(NSString *)service
                                    error:(NSError * _Nullable * _Nullable)error;

/// Whether the connection has been interrupted or invalidated.
@property (atomic, readonly) BOOL lost;

/// Send `message` without a reply. `completion` runs on `queue` once the
/// message has left this process, with nil, or with an error when the
/// connection was already lost. Leaving the process says nothing about
/// whether the daemon acted on it.
- (void)sendMessage:(xpc_object_t)message
    completionQueue:(dispatch_queue_t)queue
         completion:(void (^)(NSError * _Nullable error))completion;

/// Send `message` and wait up to `timeout` for the reply. Nil on a timeout,
/// a lost connection, or an XPC error reply.
- (nullable xpc_object_t)sendRequest:(xpc_object_t)message
                             timeout:(NSTimeInterval)timeout
                               error:(NSError * _Nullable * _Nullable)error;

/// Close the connection. Further sends complete with an error.
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
