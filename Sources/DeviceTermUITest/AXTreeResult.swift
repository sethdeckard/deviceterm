// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One shaped accessibility tree, plus what the walk could not do.
///
/// The two flags are separate because they call for different responses.
/// `truncated` means a ceiling ran out, so the tree is real as far as it
/// goes and raising a limit would reveal more. `unreadable` means a read
/// failed, so part of the tree is unknown rather than absent, and a caller
/// that treats it as absent reports an empty UI it never observed.
struct AXTreeResult {
    var tree: [String: Any]
    let truncated: Bool
    let unreadable: Bool
}
