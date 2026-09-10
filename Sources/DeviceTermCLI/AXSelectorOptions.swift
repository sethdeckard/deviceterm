// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser

/// The accessibility selector `tap` and `wait ax` share: `--identifier`
/// or `--label`, narrowed by `--role`, `--value`, and `--match`,
/// observed through `--source` with its `--step` and `--budget`.
///
/// One declaration for both verbs, so a selector cannot come to mean one
/// thing to the wait and another to the tap that acts on it.
struct AXSelectorOptions: ParsableArguments {
    @Option(name: .long, help: "Match on the element's accessibility identifier.")
    var identifier: String?

    @Option(name: .long, help: "Match on the element's label.")
    var label: String?

    @Option(name: .long, help: "Narrow to elements of this role.")
    var role: String?

    @Option(name: .long, help: "Narrow to elements carrying this value.")
    var value: String?

    @Option(
        name: .long,
        help: "How the needle matches: exact or contains.",
        completion: .list(Completions.matchValues)
    )
    var match: String?

    @Option(
        name: .long,
        help: "Where to observe from: tree or sweep.",
        completion: .list(Completions.sourceValues)
    )
    var source: String?

    @Option(name: .long, help: "Sweep spacing, 0...1. Requires --source sweep.")
    var step: Double?

    @Option(name: .long, help: "Sweep budget in milliseconds. Requires --source sweep.")
    var budget: Int?

    /// Read the selector, or the reason it cannot be read.
    ///
    /// `verb` names the caller in the exactly-one-selector message, the
    /// only rejection whose wording depends on who asked.
    func resolve(verb: String) -> CLICommands.AXSelectorParse {
        guard (identifier == nil) != (label == nil) else {
            return .usage("deviceterm: \(verb) requires exactly one of --identifier or --label")
        }
        guard let matchMode = CLICommand.WaitAXMatchMode(rawValue: match ?? "exact") else {
            return .usage("deviceterm: --match must be exact or contains")
        }
        // An empty needle is a legitimate exact query for an empty
        // attribute, but under `contains` it matches every string-valued
        // instance of that attribute.
        if matchMode == .contains, (identifier ?? label)?.isEmpty == true {
            return .usage(
                "deviceterm: --match contains requires a non-empty --identifier or --label"
            )
        }
        // `--value` narrows an element the caller already named. It needs
        // no requires-a-selector check of its own: the exactly-one guard
        // above already refuses a call with neither.
        if matchMode == .contains, value?.isEmpty == true {
            return .usage("deviceterm: --match contains requires a non-empty --value")
        }
        guard let resolvedSource = CLICommand.WaitAXSource(rawValue: source ?? "tree") else {
            return .usage("deviceterm: --source must be tree or sweep")
        }
        if resolvedSource == .tree, step != nil || budget != nil {
            return .usage("deviceterm: --step and --budget require --source sweep")
        }
        return .query(
            CLICommand.WaitAXQuery(
                identifier: identifier,
                label: label,
                role: role,
                value: value,
                matchMode: matchMode,
                source: resolvedSource,
                step: step,
                budgetMs: budget
            )
        )
    }
}
