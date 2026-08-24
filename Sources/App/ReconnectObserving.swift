// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Role protocol: observe connection re-establishment.
///
/// After a reconnect (daemon respawn or XPC interruption), the daemon's
/// in-memory terminal-anchor store is gone or the prior connection's anchors
/// were revoked. The terminal-pane container registers here so it can re-bind
/// every live terminal once the connection is back. Idempotent binds make a
/// duplicate notification harmless. The returned token MUST be removed on tab
/// teardown; otherwise the registry accumulates dead closures across tab
/// open/close cycles.
@MainActor
protocol ReconnectObserving: AnyObject {
    func addReconnectObserver(_ handler: @escaping @MainActor () -> Void) -> ReconnectObserverToken
    func removeReconnectObserver(_ token: ReconnectObserverToken)
}
