// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Opaque handle for a registered reconnect observer, so a closing tab can
/// remove its observer and the client's registry doesn't grow unboundedly.
struct ReconnectObserverToken: Hashable, Sendable {
    let id: UUID
}
