// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser
@testable import DeviceTermCLI
import Testing

// The command tree read back off the parser, and the rejection surface
// every declared verb owes its callers.

// MARK: - Detection drift guard

@Test
func everyDeclaredCommandCarriesItsCLICommand() {
    // Help is recognized by elimination: a parse result that is not one
    // of ours is ArgumentParser's own help command, whose type is not
    // exported and so cannot be matched directly. A command that drops
    // the conformance therefore stops running and starts printing a help
    // page, with nothing in the build to say so. This is the check that
    // says so.
    for command in CommandTree.allCommands {
        #expect(
            command is any CLICommandConvertible.Type,
            "\(CommandTree.name(of: command)) does not conform to CLICommandConvertible"
            )
    }
}

@Test
func commandTreeReportsTheDeclaredVerbs() {
    let names = Set(CommandTree.subcommands(of: DeviceTerm.self).map { CommandTree.name(of: $0) })
    #expect(names == CLICommands.portedVerbs)
}

@Test
func rootCommandIsNamedForTheSymlinkNotTheBinary() {
    // The target builds `deviceterm-cli` and is symlinked as
    // `deviceterm`. ArgumentParser's synthesized usage lines read this.
    #expect(DeviceTerm.configuration.commandName == "deviceterm")
}

// MARK: - Generated help

@Test("a declared verb's help is the generated page", arguments: [
    "text", "tabs", "panes", "devices", "windows",
    "doctor", "version", "dump-config", "events", "agents"
])
func declaredVerbRendersGeneratedHelp(verb: String) {
    // The declaration is the grammar, so the page has to come from it.
    // A hand-written page for a declared verb can contradict the parser,
    // leaving a reader who follows it wrong rather than merely
    // under-informed.
    let page = String(data: helpOutcome(topic: verb).stdout, encoding: .utf8) ?? ""
    #expect(page.contains("USAGE: deviceterm \(verb)"), "no generated usage line for \(verb): \(page)")
}

@Test("a leaf verb's page lists the flags it declares", arguments: [
    "text", "doctor", "version", "dump-config", "events", "agents"
])
func leafVerbPageListsItsFlags(verb: String) {
    let page = String(data: helpOutcome(topic: verb).stdout, encoding: .utf8) ?? ""
    #expect(page.contains("OPTIONS:"), "\(verb) page has no options section")
    #expect(page.contains("--json"), "\(verb) page omits its declared --json flag")
}

@Test("a parent verb's page names its sub-verbs", arguments: [
    ("tabs", ["list", "current"]),
    ("panes", ["list"]),
    ("devices", ["list"]),
    ("windows", ["list"])
])
func parentVerbPageNamesSubVerbs(verb: String, subVerbs: [String]) {
    let page = String(data: helpOutcome(topic: verb).stdout, encoding: .utf8) ?? ""
    #expect(page.contains("SUBCOMMANDS:"), "\(verb) page has no subcommands section")
    for subVerb in subVerbs {
        #expect(page.contains(subVerb), "\(verb) page omits sub-verb \(subVerb)")
    }
}

@Test
func freeTextRefusalNamesTheTerminator() {
    // The diagnostic has to name the terminator, so a caller who sent a
    // dashed payload word can correct it from the refusal alone.
    guard case let .usage(message) = CLICommands.parse(
        ["deviceterm", "text", "hello", "--world"]
    ) else {
        Issue.record("expected .usage")
        return
    }
    let text = message ?? ""
    #expect(text.contains("--world"), "refusal does not name the rejected token")
    #expect(text.contains("Put -- before the text"), "refusal does not name the fix: \(text)")
}

@Test
func nonFreeTextRefusalOmitsTheTerminatorHint() {
    // `--` is not the answer on a verb with fixed operands, so the cue
    // would be noise there.
    guard case let .usage(message) = CLICommands.parse(["deviceterm", "doctor", "--nope"]) else {
        Issue.record("expected .usage")
        return
    }
    #expect(!(message ?? "").contains("Put -- before"))
}

@Test
func freeTextRefusalOmitsTheHintWhenNoFlagWasUnknown() {
    // A missing value is a different mistake and takes a different fix.
    guard case let .usage(message) = CLICommands.parse(["deviceterm", "text", "--pane"]) else {
        Issue.record("expected .usage")
        return
    }
    #expect(!(message ?? "").contains("Put -- before"))
}

@Test
func freeTextPageStatesTheTerminatorRule() {
    // The parser refuses a dash-prefixed payload word, so the page has
    // to say how to type one. Without it, a caller discovers the
    // required terminator only by hitting the error.
    let page = String(data: helpOutcome(topic: "text").stdout, encoding: .utf8) ?? ""
    #expect(page.contains("--"), "text page does not mention the terminator")
    #expect(
        page.lowercased().contains("beginning with -"),
        "text page does not say a dashed word is read as a flag: \(page)"
        )
}

@Test
func generatedHelpKeepsTheWrittenProse() {
    // Delegating to the generated page must not drop what the written
    // page carried: its detail block and its group note.
    let page = String(data: helpOutcome(topic: "text").stdout, encoding: .utf8) ?? ""
    let written = HelpText.page(forTopic: "text") ?? ""
    #expect(!written.isEmpty)
    for line in written.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
        #expect(page.contains(line), "generated page dropped: \(line)")
    }
}

@Test("both help spellings render one page", arguments: [
    ["text"], ["doctor"], ["windows", "list"], ["tabs", "current"]
])
func helpSpellingsAgree(path: [String]) {
    // `help <path>` and `<path> --help` resolve the same command, so a
    // reader cannot be shown two different accounts of one verb.
    let viaHelpVerb = CLICommands.parse(["deviceterm", "help"] + path)
    let viaFlag = CLICommands.parse(["deviceterm"] + path + ["--help"])
    #expect(viaHelpVerb == viaFlag)
    #expect(viaFlag == .help(topic: path.joined(separator: " ")))
}

// MARK: - Unknown-flag rejection

/// Every declared verb and sub-verb, as argv prefixes.
let declaredInvocations: [[String]] = [
    ["text", "hello"],
    ["tabs", "list"],
    ["tabs", "current"],
    ["panes", "list"],
    ["devices", "list"],
    ["windows", "list"],
    ["doctor"],
    ["version"],
    ["dump-config"],
    ["events"],
    ["agents"]
]

@Test("unknown flags are refused", arguments: declaredInvocations)
func unknownFlagIsRejected(invocation: [String]) {
    let parsed = CLICommands.parse(["deviceterm"] + invocation + ["--nope"])
    guard case let .usage(message) = parsed else {
        Issue.record("expected .usage for \(invocation) --nope, got \(parsed)")
        return
    }
    #expect(message?.contains("--nope") ?? false)
}

@Test("the parent verbs name their sub-verbs when misused", arguments: [
    (["tabs"], ["list", "current"]),
    (["panes"], ["list"]),
    (["devices"], ["list"]),
    (["windows"], ["list"])
])
func parentVerbNamesItsSubVerbs(invocation: [String], expected: [String]) {
    for argv in [invocation, invocation + ["burn"]] {
        let parsed = CLICommands.parse(["deviceterm"] + argv)
        guard case let .usage(message) = parsed else {
            Issue.record("expected .usage for \(argv), got \(parsed)")
            return
        }
        let text = message ?? ""
        for subVerb in expected {
            #expect(text.contains(subVerb), "\(argv) should name '\(subVerb)': \(text)")
        }
    }
}
