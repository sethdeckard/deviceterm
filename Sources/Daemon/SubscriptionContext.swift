// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Transport-created per-subscription context handed to a subscription
/// handler. `subscriptionToken` is the correlation key for the
/// connection's side-band surface lane (and, for a device pane, the
/// pool's lease token); `connectionId` is the registering connection,
/// used for the pool's connection-authority check. UDS subscriptions
/// pass `nil`: UDS vends no surface lane, so there is nothing to
/// correlate or drain.
public struct SubscriptionContext: Sendable {
    let subscriptionToken: UUID
    let connectionId: UInt64
    let lifecycle: SubscriptionLifecycle
    /// Pane-agnostic side-band delivery capability: marshals a
    /// `SurfaceSendInfo` and ships it on the registering connection's
    /// peer. Pane-agnostic by construction, it reads `info.paneId` and
    /// asserts no pane of its own, so the transport hands the
    /// coordinator the *ability* to deliver a surface without naming (or
    /// authorizing) a pane. `PaneCoordinator.subscribe` registers it
    /// against the authorized pane *after* the ownership gate, so a
    /// foreign subscribe never wires a delivery slot: registration happens
    /// only after ownership authorization.
    let surfaceDelivery: PaneSubscriptionRegistry.SurfaceDelivery

    init(
        subscriptionToken: UUID,
        connectionId: UInt64,
        lifecycle: SubscriptionLifecycle,
        surfaceDelivery: @escaping PaneSubscriptionRegistry.SurfaceDelivery
    ) {
        self.subscriptionToken = subscriptionToken
        self.connectionId = connectionId
        self.lifecycle = lifecycle
        self.surfaceDelivery = surfaceDelivery
    }
}
