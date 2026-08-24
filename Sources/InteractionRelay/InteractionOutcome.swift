// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The result of performing an intent. Most intents just acknowledge; a rotate
/// reports the orientation the device settled on.
package enum InteractionOutcome: Sendable, Equatable {
    case acknowledged
    case orientation(String?)
}
