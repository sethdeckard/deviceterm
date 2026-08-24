// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation

/// Semantic tint for the pill's icon, resolved to a system color by the
/// view. The pill background stays neutral in every state; only the icon
/// carries color, and the accent appears only where there's something to
/// act on.
enum UpdateTint: Equatable {
    case neutral
    case accent
    case positive
    case negative
}
