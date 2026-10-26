// SPDX-License-Identifier: GPL-3.0-or-later

#import "SimRemoteHIDChannel.h"
#import "SimHIDSendLedger.h"

#import <CoreSimulator/SimDevice.h>

#import <dlfcn.h>
#import <mach/mach.h>

/// `xpc_endpoint_t xpc_endpoint_create_mach_port_4sim(mach_port_t)`: libSystem
/// SPI that wraps a Mach port from a simulator's bootstrap as an endpoint.
typedef xpc_endpoint_t (*CSBEndpointFromSimPortFn)(mach_port_t port);

/// `void xpc_connection_enable_sim2host_4sim(xpc_connection_t)`: libSystem SPI
/// that marks a connection as running from the host into a simulator.
typedef void (*CSBEnableSimToHostFn)(xpc_connection_t connection);

static NSError *CSBRemoteError(NSString *description) {
    return [NSError errorWithDomain:CSBHIDClientErrorDomain
                               code:CSBHIDClientErrorRemoteUnavailable
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

/// `CSBRemoteError`, keeping the error that caused it as the underlying one.
static NSError *CSBRemoteErrorCausedBy(NSString *description, NSError *cause) {
    return [NSError errorWithDomain:CSBHIDClientErrorDomain
                               code:CSBHIDClientErrorRemoteUnavailable
                           userInfo:@{NSLocalizedDescriptionKey: description, NSUnderlyingErrorKey: cause}];
}

@interface SimRemoteHIDChannel ()
@property (atomic, readwrite) BOOL lost;
@property (nonatomic, strong) xpc_connection_t connection;
/// Held for the connection's lifetime, since it wraps the service's port.
@property (nonatomic, strong) xpc_endpoint_t endpoint;
@property (nonatomic, copy) NSString *service;
@end

@implementation SimRemoteHIDChannel

+ (nullable instancetype)channelForDevice:(SimDevice *)device
                                  service:(NSString *)service
                                    error:(NSError **)error {
    CSBEndpointFromSimPortFn makeEndpoint =
        (CSBEndpointFromSimPortFn)dlsym(RTLD_DEFAULT, "xpc_endpoint_create_mach_port_4sim");
    CSBEnableSimToHostFn enableSimToHost =
        (CSBEnableSimToHostFn)dlsym(RTLD_DEFAULT, "xpc_connection_enable_sim2host_4sim");
    if (!makeEndpoint || !enableSimToHost) {
        if (error) *error = CSBRemoteError(@"The XPC SPI that reaches a simulator's services is unavailable.");
        return nil;
    }
    NSError *lookupError = nil;
    mach_port_t port = [device lookup:service error:&lookupError];
    if (port == MACH_PORT_NULL) {
        if (error) {
            NSString *description = [NSString stringWithFormat:@"%@ is not in the simulator's bootstrap.", service];
            *error = lookupError
                ? CSBRemoteErrorCausedBy([NSString stringWithFormat:@"%@ is not in the simulator's bootstrap: %@",
                                                                    service, lookupError.localizedDescription],
                                         lookupError)
                : CSBRemoteError(description);
        }
        return nil;
    }
    // The send right is left alone: whether the endpoint takes it over is
    // unverified, and releasing one the endpoint still uses would break the
    // connection.
    xpc_endpoint_t endpoint = makeEndpoint(port);
    if (!endpoint) {
        if (error) *error = CSBRemoteError([NSString stringWithFormat:@"No endpoint for %@.", service]);
        return nil;
    }
    xpc_connection_t connection = xpc_connection_create_from_endpoint(endpoint);
    if (!connection) {
        if (error) *error = CSBRemoteError([NSString stringWithFormat:@"No connection to %@.", service]);
        return nil;
    }
    enableSimToHost(connection);

    SimRemoteHIDChannel *channel = [SimRemoteHIDChannel new];
    channel.service = service;
    channel.connection = connection;
    channel.endpoint = endpoint;
    xpc_connection_set_target_queue(connection, dispatch_queue_create("deviceterm.hid.remote", DISPATCH_QUEUE_SERIAL));
    __weak SimRemoteHIDChannel *weakChannel = channel;
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
        if (xpc_get_type(event) == XPC_TYPE_ERROR) weakChannel.lost = YES;
    });
    xpc_connection_resume(connection);
    return channel;
}

- (void)sendMessage:(xpc_object_t)message
    completionQueue:(dispatch_queue_t)queue
         completion:(void (^)(NSError *))completion {
    if (self.lost) {
        NSString *description = [NSString stringWithFormat:@"The connection to %@ was lost.", self.service];
        dispatch_async(queue, ^{ completion(CSBRemoteError(description)); });
        return;
    }
    xpc_connection_send_message(self.connection, message);
    xpc_connection_send_barrier(self.connection, ^{
        dispatch_async(queue, ^{ completion(nil); });
    });
}

- (nullable xpc_object_t)sendRequest:(xpc_object_t)message
                             timeout:(NSTimeInterval)timeout
                               error:(NSError **)error {
    if (self.lost) {
        if (error) *error = CSBRemoteError([NSString stringWithFormat:@"The connection to %@ was lost.", self.service]);
        return nil;
    }
    __block xpc_object_t received = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    xpc_connection_send_message_with_reply(self.connection, message,
                                           dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
                                           ^(xpc_object_t reply) {
        received = reply;
        dispatch_semaphore_signal(done);
    });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))) != 0) {
        if (error) {
            *error = CSBRemoteError([NSString stringWithFormat:@"%@ did not answer within %.1fs.", self.service, timeout]);
        }
        return nil;
    }
    if (xpc_get_type(received) == XPC_TYPE_ERROR) {
        self.lost = YES;
        if (error) {
            const char *reason = xpc_dictionary_get_string(received, XPC_ERROR_KEY_DESCRIPTION);
            *error = CSBRemoteError([NSString stringWithFormat:@"%@ refused the request: %s", self.service,
                                     reason ?: "unknown XPC error"]);
        }
        return nil;
    }
    return received;
}

- (void)invalidate {
    self.lost = YES;
    xpc_connection_cancel(self.connection);
}

- (void)dealloc {
    xpc_connection_cancel(_connection);
}

@end
