// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What the argv resolves to.
enum UITestCommand: Equatable {
    /// Run as the resident harness (binds the socket, serves requests).
    case serve
    /// Connect to the resident and perform one request.
    case client(UITestRequest)
    /// Print help and exit 0.
    case usage
}
