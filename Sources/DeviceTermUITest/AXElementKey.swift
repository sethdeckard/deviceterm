// SPDX-License-Identifier: GPL-3.0-or-later

import ApplicationServices
import Foundation

/// A hashable identity for one `AXUIElement`, so a walk can tell whether it
/// has already visited an element.
///
/// `AXUIElement` is a CoreFoundation type: two references to the same element
/// are not necessarily the same pointer, so `===` says nothing useful and
/// `CFEqual` is the comparison the API supports. `CFHash` agrees with it, as
/// CoreFoundation requires of any type implementing both.
///
/// What the headers do not promise is that two separate reads of the same
/// element compare equal, so a guard keyed on this catches a repeat only when
/// accessibility hands back a matching element. `AXTraversalPolicy` carries
/// the rule that does not depend on that.
struct AXElementKey: Hashable {
    let element: AXUIElement

    init(_ element: AXUIElement) {
        self.element = element
    }

    static func == (lhs: AXElementKey, rhs: AXElementKey) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}
