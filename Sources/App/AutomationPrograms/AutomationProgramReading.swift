// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol

/// The narrow role the intent layer needs from supervision: report the
/// configured programs, and re-run them.
///
/// Narrow because `IntentDispatcher` has no business with the rest of the
/// coordinator, and because a fake makes the two verbs testable without a
/// workspace.
@MainActor
protocol AutomationProgramReading: AnyObject {
    /// Every configured program, in file order, including entries that are
    /// stopped or given up on. A caller asking "what is going on" needs the
    /// ones that are not running most of all.
    func status() -> [AutomationProgramStatus]

    /// Re-run `name`, or every configured program when nil, clearing any
    /// failure first. Answers the status as it stands afterwards.
    ///
    /// Throws when `name` matches no configured entry, which is the one way
    /// this verb can be wrong about something the caller typed.
    func restart(name: String?) async throws -> [AutomationProgramStatus]
}
