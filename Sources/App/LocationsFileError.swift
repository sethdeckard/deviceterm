// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import os

enum LocationsFileError: Error, Equatable {
    /// The file exists but couldn't be decoded, so its contents are
    /// unknown and must not be replaced.
    case unreadable(path: String)
}
