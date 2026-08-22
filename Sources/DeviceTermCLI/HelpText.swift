// SPDX-License-Identifier: GPL-3.0-or-later
//
// HelpText: renders the `deviceterm help` surface from `HelpCatalog`.
//
// Two shapes come out of here. `overview` is what a bare `deviceterm help`
// prints: one line per top-level verb, grouped by the job it does, with the
// concepts named at the foot. `page(forTopic:)` is what `deviceterm help
// <command>` prints: that topic's reference block plus whatever context its
// group carries. Subcommands (`tab open`, `ax sweep`) never reach the
// overview; they live on their parent verb's page.
//
// Text is wrapped to 78 columns so it reads in any 80-col terminal.
// `render(role:)` prepends a role-aware header, so a caller can see which
// role the daemon gave it. That header is the only role-varying part of the
// output. The verb list is never filtered: an automation-only verb like
// `tab send-input` appears in every caller's view, and a listed command may
// still be refused because the connection lacks the required grant.
//
// A topic page carries no role header. It answers "how does this work?"
// rather than "what may I run?", which also means it needs no daemon
// round-trip: `deviceterm help crown` works with the daemon stopped.

import DaemonProtocol

public enum HelpText {
    /// The banner every overview opens with: what deviceterm is, then the
    /// one-line grammar.
    static let banner = """
    deviceterm is a macOS terminal where Apple devices behave as
    first-class panes inside the tab: booted simulators (iOS, watchOS,
    iPadOS, tvOS) and physically-connected iPhones/iPads.

    Usage: deviceterm <command> [args…] [--pane <ref>]
    """

    /// Where to go for more than one line per verb.
    static let footer = """
    `deviceterm help <command>` reads one command in full, `deviceterm
    help <topic>` a concept. `deviceterm agents` is the workflow + triage
    guide.
    """

    /// Width of the verb column, sized to the catalog so a longer verb
    /// can't silently push its summary out of alignment.
    static let nameColumn: Int = (HelpCatalog.commandNames.map(\.count).max() ?? 0) + 2

    /// The shape printed for `deviceterm help` / `--help` / `-h`.
    public static let overview: String = {
        var lines = [banner, ""]
        for group in HelpTopic.Group.allCases {
            let members = HelpCatalog.topics(in: group)
            guard !members.isEmpty else { continue }
            let aside = group.titleAside.map { "  (\($0))" } ?? ""
            lines.append(group.title + aside)
            for topic in members {
                let padding = String(
                    repeating: " ",
                    count: max(1, nameColumn - topic.name.count)
                )
                lines.append("  " + topic.name + padding + topic.summary)
            }
            lines.append("")
        }
        lines.append("Concepts: " + HelpCatalog.conceptNames.joined(separator: ", "))
        lines.append("")
        lines.append(footer)
        return lines.joined(separator: "\n") + "\n"
    }()

    /// One line naming the role the daemon assigned this caller.
    ///
    /// The role is descriptive metadata, not an authorization summary:
    /// what a call is admitted to do follows the session's live
    /// automation grant and its transport. The list below it is
    /// unfiltered, so "reference" rather than "available" is the honest
    /// framing. A listed command can still be refused.
    ///
    ///   - `role: nil`: no session creds. Out-of-tab callers see "no
    ///     deviceterm session" so they know the session-scoped verbs below
    ///     won't work for them; the daemon rejects them with
    ///     `unauthorized` if invoked.
    ///   - `role: .agent` / `.automation`: in-tab.
    public static func roleHeader(role: SessionRole?) -> String {
        switch role {
        case .agent:
            "Command reference (session role: agent)\n"

        case .automation:
            "Command reference (session role: automation)\n"

        case .none:
            "Command reference (no deviceterm session)\n"
        }
    }

    /// Final rendered overview: header, a blank line, then the command
    /// list. The entry point `main.swift` uses; the bare `overview`
    /// constant stays for tests that pin body invariants without caring
    /// about the role header.
    public static func render(role: SessionRole?) -> String {
        roleHeader(role: role) + "\n" + overview
    }

    /// One topic's reference page, or nil when `name` isn't a topic.
    ///
    /// Returns a `String` rather than the topic so `HelpCatalog`'s types
    /// stay internal to the module.
    public static func page(forTopic name: String) -> String? {
        guard let topic = HelpCatalog.topic(named: name) else { return nil }
        guard let note = topic.group?.note else { return topic.detail + "\n" }
        return topic.detail + "\n\n" + note + "\n"
    }

    /// Stderr text for `deviceterm help <something-that-isn't-a-topic>`.
    public static func unknownTopicMessage(_ name: String) -> String {
        var lines = ["unknown help topic '\(name)'"]
        let near = HelpCatalog.suggestions(for: name)
        if !near.isEmpty {
            lines.append("did you mean: " + near.joined(separator: ", ") + "?")
        }
        lines.append("run `deviceterm help` for the command list")
        return lines.joined(separator: "\n")
    }
}
