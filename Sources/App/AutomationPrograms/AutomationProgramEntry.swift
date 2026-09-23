// SPDX-License-Identifier: GPL-3.0-or-later

/// One `program` block from `<config home>/deviceterm/automation-programs`:
/// a command deviceterm runs in an Automation tab of its own at launch.
///
/// Pure data. Every field is already resolved against the file that carried
/// it, so nothing downstream needs to know where that file lived.
struct AutomationProgramEntry: Equatable, Sendable {
    /// The block's name. Unique across the file, and the tab's title.
    let name: String

    /// The command line, as a single element.
    ///
    /// An array rather than a `String` because that is the shape a tab
    /// command takes on the wire; `tab open --command '<cmd>'` wraps its one
    /// string the same way, so quoting means the same thing in both.
    /// `TabContentViewController.runAutomationCommand(grantedTo:)` joins the
    /// elements with a space and sends them with a trailing newline once the
    /// tab's grant applies.
    let command: [String]

    /// The shell's working directory, absolute. Defaults to the home
    /// directory when the block does not say.
    let cwd: String

    /// Whether deviceterm re-runs the command when the program exits.
    /// Defaults to true when the block does not say.
    let restart: Bool
}
