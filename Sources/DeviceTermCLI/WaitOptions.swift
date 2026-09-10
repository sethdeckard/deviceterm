// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser

/// The flags every `wait` sub-verb accepts, so each can refuse the ones
/// another owns by name.
///
/// Declaring the union rather than only a sub-verb's own flags is what
/// makes the refusal possible: an undeclared flag is refused as unknown,
/// which says nothing about the wait that does take it. Dropping the
/// flag instead would be worse than either, because `wait pane rendering
/// --label Save` reads as a wait for a labelled element and would report
/// success without having looked for the label at all.
struct WaitOptions: ParsableArguments {
    @Option(name: .long, help: "Deadline in milliseconds.")
    var timeout: Int?

    @Option(name: .long, help: "Window of stillness in milliseconds. `wait surface` only.")
    var settle: Int?

    @Option(name: .long, help: "What to print on success. `wait ax` only.")
    var print: String?

    @Option(name: .long, help: "Wait for the element to be present or absent. `wait ax` only.")
    var state: String?

    @OptionGroup var selector: AXSelectorOptions
    @OptionGroup var paneOption: PaneOption
    @OptionGroup var jsonFlag: JSONFlag

    /// The flags actually given, keyed the way `waitExclusiveFlags` keys
    /// them, so ownership is decided by one table rather than per verb.
    var presentFlags: [String: String] {
        var flags: [String: String] = [:]
        let named: [(String, String?)] = [
            ("identifier", selector.identifier),
            ("label", selector.label),
            ("role", selector.role),
            ("value", selector.value),
            ("match", selector.match),
            ("source", selector.source),
            ("print", print),
            ("state", state),
            ("settle", settle.map(String.init))
        ]
        for (name, value) in named {
            flags[name] = value
        }
        return flags
    }

    /// The deadline, defaulted.
    var deadlineMillis: Int { timeout ?? CLICommands.defaultTimeoutMillis }

    /// The refusal for a deadline that cannot elapse, or nil when the
    /// deadline is usable.
    var timeoutRefusal: CLICommand? { CLICommands.timeoutRefusal(timeout) }

    /// The usage error for a wait carrying a flag another wait owns, or
    /// nil when every flag it was given belongs to it.
    func foreignFlagRefusal(subVerb: String) -> CLICommand? {
        CLICommands.foreignWaitFlagRefusal(
            subVerb: subVerb,
            flags: presentFlags,
            step: selector.step,
            budgetMs: selector.budget
        )
    }
}
