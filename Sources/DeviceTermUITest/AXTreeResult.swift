// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One shaped accessibility tree, plus what the walk could not do.
///
/// The two flags are separate because they call for different responses.
/// `truncated` means a ceiling ran out, so the tree is real as far as it
/// goes and raising a limit would reveal more. `unreadable` means the tree's
/// structure or a node's identity is uncertain: some node failed a structural
/// or identifying read, so a part of it is unknown rather than absent, and a
/// caller that treats it as absent reports an empty UI it never observed.
///
/// A read that failed on any other attribute is recorded on its node and does
/// not raise this flag. See `AXTreeBuilder.structuralAttributes`.
struct AXTreeResult {
    var tree: [String: Any]
    let truncated: Bool
    let unreadable: Bool
}
