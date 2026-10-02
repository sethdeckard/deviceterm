// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A feature call the device answered with an error instead of a result.
///
/// Carries the device's own explanation, such as a minimum OS requirement, so
/// it can reach the user rather than collapsing into "no output".
package struct DeviceRefusal: Error, Sendable, Equatable, CustomStringConvertible {
    /// The device's localized description, or its error domain and code when
    /// it sent no description.
    package let reason: String

    package var description: String { reason }

    package init(reason: String) {
        self.reason = reason
    }
}
