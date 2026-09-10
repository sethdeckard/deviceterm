// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser

/// `deviceterm tap <x> <y>` or `deviceterm tap --identifier|--label ...`.
///
/// A selector flag is what picks the form. Coordinates and a selector
/// together are a usage error rather than a precedence rule, because a
/// caller who wrote both cannot be read as meaning either.
struct TapCommand: CLICommandConvertible {
    static let configuration = CommandConfiguration(
        commandName: "tap",
        abstract: "Single discrete tap, by coordinate or selector",
        usage: CLICommands.tapUsage,
        discussion: HelpText.page(forTopic: "tap") ?? ""
    )

    @Argument(help: "X in 0...1. Omit when selecting by identifier or label.")
    var x: Double?

    @Argument(help: "Y in 0...1. Omit when selecting by identifier or label.")
    var y: Double?

    @Option(name: .long, help: "How long to wait for the selector to resolve, in milliseconds.")
    var timeout: Int?

    @OptionGroup var selector: AXSelectorOptions
    @OptionGroup var paneOption: PaneOption
    @OptionGroup var jsonFlag: JSONFlag

    var cliCommand: CLICommand {
        if let refusal = CLICommands.timeoutRefusal(timeout) { return refusal }
        let deadline = timeout ?? CLICommands.defaultTimeoutMillis
        if selector.identifier != nil || selector.label != nil {
            guard x == nil, y == nil else { return .usage(message: Self.usageRefusal) }
            switch selector.resolve(verb: "tap") {
            case let .usage(message):
                return .usage(message: message)

            case let .query(query):
                return .tapElement(pane: paneOption.pane, query: query, timeoutMs: deadline)
            }
        }
        guard let x, let y else { return .usage(message: Self.usageRefusal) }
        if let orphan = orphanedSelectorFlag {
            return .usage(
                message: "deviceterm: --\(orphan) applies to `tap --identifier` or `tap --label`"
                )
        }
        if let outside = CLICommands.firstCoordinateOutsideUnitRange([x, y]) {
            return .usage(message: CLICommands.coordinateRangeUsage(outside))
        }
        return .tap(pane: paneOption.pane, x: x, y: y)
    }

    /// The first flag that says nothing until `tap` has a selector to
    /// narrow, in the order the usage message names them.
    ///
    /// A coordinate tap carrying one was written for the selector form,
    /// so tapping the coordinates and ignoring the rest would run a
    /// command nobody asked for.
    private var orphanedSelectorFlag: String? {
        let flags: [(name: String, isSet: Bool)] = [
            ("role", selector.role != nil),
            ("value", selector.value != nil),
            ("match", selector.match != nil),
            ("source", selector.source != nil),
            ("step", selector.step != nil),
            ("budget", selector.budget != nil),
            ("timeout", timeout != nil)
        ]
        return flags.first(where: \.isSet)?.name
    }
}
