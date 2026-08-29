// SPDX-License-Identifier: GPL-3.0-or-later

extension CLICommand {
    /// Commands whose normal output is JSON even without `--json`.
    var emitsJSONByDefault: Bool {
        switch self {
        case .axTree, .axPoint, .axSweep, .events:
            return true

        default:
            return false
        }
    }

    /// Usage emits its exact stderr block without the driver's
    /// `deviceterm:` prefix.
    var emitsUnprefixedStderr: Bool {
        if case .usage = self { return true }
        return false
    }
}
