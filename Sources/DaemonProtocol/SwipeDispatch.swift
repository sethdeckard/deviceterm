// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// How the daemon's interpolation loop dispatched the gesture. `tap` means
/// zero or one interpolated sample was submitted; `drag` means more than one.
///
/// A gesture reaches `tap` three ways: the caller's `durationMs` was below
/// the one-frame floor of `~32ms`, the gesture ended before its samples
/// could be sent, or it ran late enough that skipping left only one.
public enum SwipeDispatch: String, Codable, Sendable, Equatable {
    case tap
    case drag
}
