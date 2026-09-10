// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser

/// The command tree, read back off the parser itself.
///
/// Reading the tree rather than restating it is what keeps a second
/// description of the grammar from falling behind the parser that
/// implements it.
enum CommandTree {
    /// One top-level verb, as the documentation guards and the
    /// completion scripts read it.
    struct Verb: Equatable {
        let name: String
        /// Sub-verbs under a hierarchical verb; empty for a flat one.
        let subVerbs: [String]
        /// The one-line summary, which is also the command list's
        /// right-hand column.
        let abstract: String
    }

    /// Every top-level verb, in declaration order.
    static var all: [Verb] {
        subcommands(of: DeviceTerm.self).map { command in
            Verb(
                name: name(of: command),
                subVerbs: subcommands(of: command).map { name(of: $0) },
                abstract: command.configuration.abstract
            )
        }
    }

    /// Every declared sub-command below the root, at any depth.
    ///
    /// Parents are included because a verb invoked without its sub-verb
    /// parses to the parent, so a parent is a value the parser can hand
    /// back and has to be able to answer for itself. The root is not: it
    /// never reaches the dispatcher, because a bare `deviceterm` is
    /// refused before parsing.
    static var allCommands: [ParsableCommand.Type] {
        var found: [ParsableCommand.Type] = []
        var pending = subcommands(of: DeviceTerm.self)
        while let command = pending.popLast() {
            found.append(command)
            pending.append(contentsOf: subcommands(of: command))
        }
        return found
    }

    /// The sub-commands of `command`, grouped and ungrouped alike.
    static func subcommands(of command: ParsableCommand.Type) -> [ParsableCommand.Type] {
        let configuration = command.configuration
        return configuration.ungroupedSubcommands
            + configuration.groupedSubcommands.flatMap(\.subcommands)
    }

    /// The sub-verbs of a top-level verb, empty when it has none or is
    /// not declared.
    static func subVerbs(of verb: String) -> [String] {
        all.first { $0.name == verb }?.subVerbs ?? []
    }

    /// The name `command` answers to on the command line.
    static func name(of command: ParsableCommand.Type) -> String {
        command.configuration.commandName
            ?? String(describing: command).lowercased()
    }

    /// Resolve a command path (`["tabs", "current"]`) to its type.
    static func command(for path: [String]) -> ParsableCommand.Type? {
        guard !path.isEmpty else { return nil }
        var current: ParsableCommand.Type = DeviceTerm.self
        for token in path {
            guard let next = subcommands(of: current).first(where: { name(of: $0) == token })
            else { return nil }
            current = next
        }
        return current
    }

    /// The longest leading run of `tokens` that names a command path.
    ///
    /// This is what lets both help spellings land on one page:
    /// `help tabs current` and `tabs current --help` resolve the same
    /// two tokens. Trailing tokens that name nothing stop the walk
    /// rather than failing it, so `help tap 0.5 0.5` still resolves
    /// `tap` once `tap` is declared, and a verb the tree does not
    /// declare resolves to nothing at all, which is the caller's cue to
    /// fall back.
    static func longestCommandPath(in tokens: [String]) -> [String] {
        var current: ParsableCommand.Type = DeviceTerm.self
        var path: [String] = []
        for token in tokens {
            guard let next = subcommands(of: current).first(where: { name(of: $0) == token })
            else { break }
            current = next
            path.append(token)
        }
        return path
    }
}
