// SPDX-License-Identifier: GPL-3.0-or-later

#import "SimHIDSendLedger.h"

NSErrorDomain const CSBHIDClientErrorDomain = @"CoreSimulatorBridge.SimHIDClient";

@interface SimHIDSendLedger ()
/// Serializes every field below.
@property (nonatomic, strong) dispatch_queue_t stateQueue;
@property (nonatomic, assign) uint64_t nextTicket;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *outstanding;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *abandoned;
@property (nonatomic, strong, nullable) NSError *lateError;
@property (nonatomic, strong) NSMutableArray<void (^)(NSError * _Nullable)> *settleHandlers;
@end

@implementation SimHIDSendLedger

- (instancetype)init {
    self = [super init];
    if (self) {
        _stateQueue = dispatch_queue_create("deviceterm.hid.ledger", DISPATCH_QUEUE_SERIAL);
        _nextTicket = 1;
        _outstanding = [NSMutableSet set];
        _abandoned = [NSMutableSet set];
        _settleHandlers = [NSMutableArray array];
    }
    return self;
}

- (NSUInteger)outstandingSendCount {
    __block NSUInteger count = 0;
    dispatch_sync(self.stateQueue, ^{
        count = self.outstanding.count;
    });
    return count;
}

- (BOOL)admitSendAsRelease:(BOOL)isRelease
                    ticket:(uint64_t *)ticket
                     error:(NSError **)error {
    __block BOOL admitted = NO;
    __block uint64_t issued = 0;
    dispatch_sync(self.stateQueue, ^{
        if (!isRelease && self.outstanding.count > 0) return;
        issued = self.nextTicket++;
        [self.outstanding addObject:@(issued)];
        admitted = YES;
    });
    if (!admitted) {
        if (error) {
            *error = [NSError errorWithDomain:CSBHIDClientErrorDomain
                                         code:CSBHIDClientErrorTransportStalled
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"HID transport stalled: an earlier send has not completed, "
                                            "so this one was not sent",
            }];
        }
        return NO;
    }
    *ticket = issued;
    return YES;
}

- (BOOL)abandonWaitForTicket:(uint64_t)ticket {
    __block BOOL abandoned = NO;
    dispatch_sync(self.stateQueue, ^{
        if (![self.outstanding containsObject:@(ticket)]) return;
        [self.abandoned addObject:@(ticket)];
        abandoned = YES;
    });
    return abandoned;
}

- (void)completeTicket:(uint64_t)ticket error:(NSError *)error {
    __block NSArray<void (^)(NSError *)> *ready = nil;
    __block NSError *late = nil;
    dispatch_sync(self.stateQueue, ^{
        NSNumber *key = @(ticket);
        if (![self.outstanding containsObject:key]) return;
        [self.outstanding removeObject:key];
        if ([self.abandoned containsObject:key]) {
            [self.abandoned removeObject:key];
            if (error && !self.lateError) self.lateError = error;
        }
        if (self.outstanding.count == 0 && self.settleHandlers.count > 0) {
            ready = [self.settleHandlers copy];
            [self.settleHandlers removeAllObjects];
            late = self.lateError;
            self.lateError = nil;
        }
    });
    for (void (^fire)(NSError *) in ready) fire(late);
}

- (void)whenSettledOnQueue:(dispatch_queue_t)queue
                   handler:(void (^)(NSError *))handler {
    void (^fire)(NSError *) = ^(NSError *late) {
        dispatch_async(queue, ^{ handler(late); });
    };
    __block BOOL settledNow = NO;
    __block NSError *late = nil;
    dispatch_sync(self.stateQueue, ^{
        if (self.outstanding.count > 0) {
            [self.settleHandlers addObject:fire];
            return;
        }
        settledNow = YES;
        late = self.lateError;
        self.lateError = nil;
    });
    if (settledNow) fire(late);
}

@end
