// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A normalised touch coordinate, origin top-left, each axis 0…1 across the
/// display. The relay scales it into the device's native range when it builds a
/// report.
package struct DevicePoint: Sendable, Equatable {
    package let x: Double
    package let y: Double

    package init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}
