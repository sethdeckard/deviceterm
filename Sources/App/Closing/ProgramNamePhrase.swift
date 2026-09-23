// SPDX-License-Identifier: GPL-3.0-or-later

/// Renders a list of configured automation program names as a phrase a
/// sentence can contain.
///
/// Separate from the alert that uses it so the wording is testable without
/// a window server.
enum ProgramNamePhrase {
    /// `a`, `a and b`, or `a, b and c`. Empty for no names, which no caller
    /// should reach: the prompt only runs when something is affected.
    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0:
            return ""

        case 1:
            return names[0]

        case 2:
            return "\(names[0]) and \(names[1])"

        default:
            return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        }
    }
}
