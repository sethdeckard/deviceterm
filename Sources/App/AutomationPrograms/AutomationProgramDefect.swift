// SPDX-License-Identifier: GPL-3.0-or-later

/// Something in `<config home>/deviceterm/automation-programs` deviceterm
/// could not use, and the block it came from.
///
/// A defect is reported once and the block is skipped; it never stops
/// deviceterm from starting, and it never stops the *other* blocks from
/// running. A file whose every block is defective behaves exactly like a
/// file with no blocks at all.
///
/// Reported: a block with no name, a block with no command, a name an
/// earlier block already took, and a file that will not decode. A field this
/// version does not recognize is none of those: it is ignored, so a file
/// written for a newer deviceterm still runs here.
struct AutomationProgramDefect: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        /// `program` with nothing after it.
        case missingName
        /// A block with no `command` line, or one whose value is empty.
        case missingCommand
        /// A second block claiming a name an earlier block already took. The
        /// earlier block wins, so file order decides.
        case duplicateName
        /// The file exists but would not decode, so its contents are unknown.
        /// Distinct from the file being absent, which is the ordinary state
        /// and means nothing is configured.
        case unreadableFile
    }

    /// The block's name, or nil when the defect is that there isn't one.
    let name: String?

    /// The 1-based line the defect is reported against: the block's own
    /// `program` line, so an editor jumps to the block rather than to
    /// whichever field happened to be wrong. Zero for `unreadableFile`,
    /// which belongs to no line.
    let line: Int

    let reason: Reason

    /// One line naming the defect, for the unified log.
    var summary: String {
        switch reason {
        case .missingName:
            return "line \(line): program needs a name"

        case .missingCommand:
            return "line \(line): program \(name ?? "") needs a command"

        case .duplicateName:
            return "line \(line): program \(name ?? "") is already defined above"

        case .unreadableFile:
            return "the file exists but could not be read"
        }
    }
}
