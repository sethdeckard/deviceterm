// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PNGWriterError: Error, Equatable {
    /// ImageIO refused to create or finalize the destination.
    case encodeFailed(path: String)
}
