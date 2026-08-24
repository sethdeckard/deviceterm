// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol

/// What one replacement helper needs to be told, and the connection it is
/// being told on, so a settle can name the attempt it belongs to.
struct OwnedSimRestore: Equatable {
    let generation: Int
    let claims: [RestoredSimOwnership]
}
