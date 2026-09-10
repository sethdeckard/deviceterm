// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser

/// `deviceterm crown <delta> [--velocity <v>] [--duration <ms>]`.
struct CrownCommand: CLICommandConvertible {
    static let configuration = CommandConfiguration(
        commandName: "crown",
        abstract: "Rotate the watchOS Digital Crown",
        usage: "deviceterm crown <delta> [--velocity <v>] [--duration <ms>] [--pane <ref>]",
        discussion: HelpText.page(forTopic: "crown") ?? ""
    )

    /// The options declared below that take a following value, which is
    /// the one thing `normalizing` needs to know to tell an option's
    /// value from the operand. An option added below belongs here too;
    /// an attached `--velocity=2` needs no entry, carrying its value
    /// already.
    static let valuedOptionNames: Set<String> = ["--velocity", "--duration", "--pane"]

    @Argument(help: "Signed rotation. Sign is direction, magnitude is distance.")
    var delta: Double

    /// `.unconditional` so a signed value reaches the option. The
    /// default strategy refuses to read `-2` as a value, because the
    /// tokenizer has already claimed it as a short option group.
    @Option(name: .long, parsing: .unconditional, help: "Rotations per second.")
    var velocity: Double?

    @Option(name: .long, help: "Rotation duration in milliseconds.")
    var duration: Int?

    @OptionGroup var paneOption: PaneOption
    @OptionGroup var jsonFlag: JSONFlag

    var cliCommand: CLICommand {
        .crown(
            pane: paneOption.pane,
            delta: delta,
            velocity: velocity,
            durationMs: duration
            )
    }

    /// Move `crown`'s signed operand behind a `--` terminator, leaving
    /// its flags where they are.
    ///
    /// A verb with a signed numeric operand normalizes its own argv this
    /// way because the tokenizer reads a leading hyphen as a short
    /// option: `-30` arrives as `-3 -0` and never reaches the operand.
    ///
    /// Anything that is not a `crown` invocation, and any argv the
    /// caller already escaped, passes through untouched. A negative
    /// number is that option's value rather than the operand only when
    /// it follows one of the options below, which is what keeps
    /// `--velocity -2 -30` reading as a signed velocity and a signed
    /// delta. Testing "follows a dashed token" instead would lose the
    /// delta, a negative velocity being dashed itself.
    static func normalizing(_ arguments: [String]) -> [String] {
        guard arguments.first == configuration.commandName,
            !arguments.contains("--") else { return arguments }
        var head: [String] = []
        var operands: [String] = []
        var previous: String?
        for token in arguments {
            let isSignedNumber = token.hasPrefix("-") && Double(token) != nil
            let isOptionValue = previous.map { valuedOptionNames.contains($0) } ?? false
            if isSignedNumber, !isOptionValue {
                operands.append(token)
            } else {
                head.append(token)
            }
            previous = token
        }
        guard !operands.isEmpty else { return arguments }
        return head + ["--"] + operands
    }
}
