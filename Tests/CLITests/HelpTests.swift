// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
@testable import DeviceTermCLI
import Foundation
import Testing

// `deviceterm help` parsing + content invariants.
//
// Parser side: the three top-level triggers (`--help`, `-h`, `help`)
// resolve to `.help`; the first non-flag token after one names a topic;
// sub-command literals (e.g. `deviceterm text --help`) stay literals
// because the trigger fires only in the verb position.
//
// Content side: the help text is where the practical gotchas have to
// live. These tests pin the content invariants so a refactor can't
// accidentally drop the crown single-shot guidance / ax-tree-empty
// pointer / crown velocity caveat / examples. The invariant spans the
// whole catalog because no single command prints every page, so a gotcha
// counts as present when some page carries it.

/// Every topic's prose, concatenated. The reference the content
/// invariants below are checked against.
private var allTopicProse: String {
    HelpCatalog.topics.map(\.detail).joined(separator: "\n")
}

// MARK: - Parser

@Test
func parseDashDashHelpResolvesToHelp() {
    #expect(CLICommands.parse(["deviceterm", "--help"]) == .help(topic: nil))
}

@Test
func parseDashHResolvesToHelp() {
    #expect(CLICommands.parse(["deviceterm", "-h"]) == .help(topic: nil))
}

@Test
func parseHelpVerbResolvesToHelp() {
    #expect(CLICommands.parse(["deviceterm", "help"]) == .help(topic: nil))
}

@Test
func parseHelpTriggersTakeFirstTrailingArgAsTopic() {
    // The first non-flag token after a trigger names a topic page. All
    // three spellings agree. Making `--help crown` behave differently
    // from `help crown` would be a trap, not a feature.
    #expect(CLICommands.parse(["deviceterm", "--help", "crown"]) == .help(topic: "crown"))
    #expect(CLICommands.parse(["deviceterm", "-h", "crown"]) == .help(topic: "crown"))
    #expect(CLICommands.parse(["deviceterm", "help", "crown"]) == .help(topic: "crown"))
}

@Test
func parseHelpIgnoresOperandsAfterTheTopic() {
    // A fat-fingered help prefix on a real command line lands on that
    // command's page rather than erroring or dumping the list.
    #expect(CLICommands.parse(["deviceterm", "help", "tap", "0.5", "0.5"]) == .help(topic: "tap"))
    #expect(
        CLICommands.parse(["deviceterm", "help", "swipe", "--duration", "250"])
        == .help(topic: "swipe")
        )
}

@Test
func parseHelpTopicResolvesSubcommandToItsParent() {
    // Topics are top-level names; a subcommand's prose lives on its
    // parent's page, so the parent is what gets addressed.
    #expect(CLICommands.parse(["deviceterm", "help", "tab", "open"]) == .help(topic: "tab"))
}

@Test
func parseHelpRejectsABareAllFlag() {
    // `--all` is not a help flag. With no topic to outrank it, it has to
    // be named rather than ignored, or a caller expecting a full dump
    // silently receives the short list and believes it is everything.
    #expect(
        CLICommands.parse(["deviceterm", "help", "--all"])
        == .usage(message: CLICommands.allFlagRejectedMessage)
        )
    #expect(
        CLICommands.parse(["deviceterm", "--help", "--all"])
        == .usage(message: CLICommands.allFlagRejectedMessage)
        )
}

@Test
func parseHelpTopicOutranksATrailingAllFlag() {
    // `--all` is a real flag on `windows list`, so a reader who copies
    // the signature into a help request must still reach the page. The
    // rejection above applies only when no topic was named; otherwise
    // the documented "operands after the topic are ignored" rule wins.
    #expect(
        CLICommands.parse(["deviceterm", "help", "windows", "list", "--all"])
        == .help(topic: "windows")
        )
    #expect(
        CLICommands.parse(["deviceterm", "help", "windows", "--all"])
        == .help(topic: "windows")
        )
}

@Test
func parseTextTreatsDashDashHelpAsLiteral() {
    // Regression guard: top-level help recognition must NOT eat
    // `--help` when it lives downstream of a command that types
    // arbitrary text. `deviceterm text --help` types the string
    // "--help", the existing wider invariant for `text` literals.
    #expect(
        CLICommands.parse(["deviceterm", "text", "--help"])
        == .text(pane: nil, text: "--help")
        )
}

@Test
func parseVerbTrailingDashDashHelpIsNotHelp() {
    // Help is recognized in the verb position only. A trailing `--help`
    // on a real verb stays that verb's problem, which is what keeps
    // `deviceterm text --help` typing a literal string. Anything that
    // makes `deviceterm crown --help` print a page has broken that.
    let parsed = CLICommands.parse(["deviceterm", "crown", "--help"])
    #expect(parsed != .help(topic: "crown"))
    #expect(parsed != .help(topic: nil))
}

@Test
func parseBareDeviceTermIsStillUsageNotHelp() {
    // `deviceterm` alone is "no command specified"; convention is
    // exit 1 + cue toward `help`. Only an explicit help trigger
    // yields `.help` with exit 0.
    #expect(CLICommands.parse(["deviceterm"]) == .usage(message: nil))
}

@Test
func parseUnknownVerbIsStillUsageNotHelp() {
    #expect(CLICommands.parse(["deviceterm", "wat"]) == .usage(message: nil))
}

// MARK: - Overview

@Test
func overviewOpensWithDeviceTermBanner() {
    // The banner has to introduce deviceterm to a reader who's never
    // heard of it: macOS terminal + Apple device panes (sims +
    // physical devices).
    #expect(HelpText.overview.hasPrefix("deviceterm is a macOS terminal"))
    #expect(HelpText.overview.contains("Apple devices"))
}

@Test
func overviewGroupsCommandsByCategory() {
    // Every section header surfaces in document order, so a reader
    // skimming top-to-bottom meets them in the sequence the work
    // happens: drive → hardware → inspect → devices → workspace →
    // setup → docs.
    let overview = HelpText.overview
    var searchIndex = overview.startIndex
    for group in HelpTopic.Group.allCases {
        guard let range = overview.range(
            of: group.title,
            range: searchIndex..<overview.endIndex
        ) else {
            Issue.record("missing group header: \(group.title)")
            return
        }
        searchIndex = range.upperBound
    }
}

@Test
func overviewListsEveryTopLevelVerb() {
    // The command list is the discovery surface: a verb the parser
    // accepts but the list omits is unreachable in practice.
    for verb in VerbCatalog.all.map(\.name) {
        #expect(
            HelpText.overview.contains("\n  \(verb) "),
            "verb missing from the command list: \(verb)"
            )
    }
}

@Test
func overviewOmitsSubcommands() {
    // Subcommands live only on their parent's page, which is what keeps
    // the command list scannable.
    for subcommand in ["tab open", "tab send-input", "ax sweep", "tabs list", "windows list"] {
        #expect(
            !HelpText.overview.contains(subcommand),
            "subcommand leaked into the command list: \(subcommand)"
            )
    }
}

@Test
func overviewStaysCompact() {
    // The ceiling is what keeps the list compact as topic prose grows,
    // one well-meaning paragraph at a time.
    let lineCount = HelpText.overview.split(separator: "\n", omittingEmptySubsequences: false).count
    #expect(lineCount <= 60, "command list is \(lineCount) lines")
}

@Test
func overviewNamesTheConceptsAndTheWayIn() {
    // A reader who needs more than one line per verb has to be told
    // where to go, or the compact list reads as the whole surface.
    #expect(HelpText.overview.contains("deviceterm help <command>"))
    #expect(!HelpText.overview.contains("man deviceterm"))
    for concept in HelpCatalog.conceptNames {
        #expect(HelpText.overview.contains(concept), "concept not named: \(concept)")
    }
}

@Test
func overviewCarriesTheCoordinateConvention() {
    // Normalized coords are the one thing a reader needs before the
    // first `tap`, so the list has to carry the convention.
    #expect(HelpText.overview.contains("coords are normalized"))
}

// MARK: - Pages

@Test
func pageRendersEveryTopicAndRejectsUnknownOnes() {
    for name in HelpCatalog.topicNames {
        let page = HelpText.page(forTopic: name)
        #expect(page != nil, "no page for topic: \(name)")
        #expect(page?.isEmpty == false, "empty page for topic: \(name)")
    }
    #expect(HelpText.page(forTopic: "wat") == nil)
    #expect(HelpText.page(forTopic: "") == nil)
}

@Test
func pageCarriesItsGroupNote() {
    // Group context has to reach the page or splitting the document
    // silently drops it: a reader who lands on `help tap` never learns
    // the coordinate convention, and one on `help tab` never learns
    // what `--tab` accepts.
    #expect(HelpText.page(forTopic: "tap")?.contains("Coords are normalized") == true)
    #expect(HelpText.page(forTopic: "tab")?.contains("Refs on the workspace verbs") == true)
}

@Test
func everyPaneTargetedPageNamesTheSelector() {
    // A reader landing straight on a command page has not seen the
    // command list's usage line, so the page itself has to say that
    // --pane exists and where the full story is. Without this, a tab
    // holding two device panes is an unexplained failure.
    for group in [HelpTopic.Group.drive, .hardware, .inspect] {
        for topic in HelpCatalog.topics(in: group) {
            let page = HelpText.page(forTopic: topic.name) ?? ""
            #expect(page.contains("--pane <ref>"), "\(topic.name) page omits --pane")
            #expect(
                page.contains("deviceterm help targeting"),
                "\(topic.name) page does not point at the targeting topic"
                )
        }
    }
}

@Test
func refsTopicScopesItselfToWorkspaceVerbs() {
    // `parsePaneRef` encodes only paneId / shortId / current, while the
    // input and AX verbs resolve a wider --pane. Stating the workspace
    // grammar unscoped would contradict `help targeting`.
    let refs = HelpText.page(forTopic: "refs") ?? ""
    #expect(refs.contains("workspace verbs"))
    #expect(refs.contains("deviceterm help targeting"))
}

@Test
func unknownTopicMessageSuggestsAndPointsHome() {
    let message = HelpText.unknownTopicMessage("cro")
    #expect(message.contains("unknown help topic 'cro'"))
    #expect(message.contains("did you mean: crown?"))
    #expect(message.contains("deviceterm help"))
    // A miss with no near neighbour still says where to go.
    let miss = HelpText.unknownTopicMessage("zzzz")
    #expect(miss.contains("unknown help topic 'zzzz'"))
    #expect(!miss.contains("did you mean"))
    #expect(miss.contains("deviceterm help"))
}

// MARK: - Content invariants

@Test
func helpListsEveryUserFacingVerb() {
    // The full verb list. Keep in sync with `CLICommands.parse`.
    // Each must surface in some topic's prose; the exact line shape is
    // the per-command synopsis area.
    let verbs = [
        "tabs list",
        "panes list",
        "devices list",
        "tap",
        "swipe",
        "long-press",
        "pinch",
        "button",
        "key",
        "text",
        "rotate",
        "crown",
        "ax tree",
        "ax point",
        "ax sweep",
        "tab open [--window <ref>]",
        "tab close",
        "tab rename",
        "tab select",
        "tab info",
        "tab move",
        "tab set-protected",
        "tab send-input",
        "tab capture",
        "pane open --terminal [--tab <ref>]",
        "pane close",
        "pane info",
        "device attach <ref>",
        "pane rename",
        "pane move",
        "window open",
        "window close",
        "window focus",
        "windows list",
        "completions install"
    ]
    let prose = allTopicProse
    for verb in verbs {
        #expect(prose.contains(verb), "verb missing from help: \(verb)")
    }
}

@Test
func helpDocumentsShellCompletionInstall() {
    // The shell-completions install path needs to be discoverable
    // from the CLI, not just `deviceterm agents` / man page.
    #expect(HelpCatalog.topic(named: "completions")?.detail.contains("completions install") == true)
}

@Test
func helpContainsAtLeastOneExamplePerVerb() {
    // These representative device-input verbs should each retain an
    // inline `deviceterm <verb>` example. Not every operand-taking verb
    // is listed; the workspace verbs are covered by their own pages.
    let verbsWithExamples = [
        "deviceterm tap",
        "deviceterm swipe",
        "deviceterm long-press",
        "deviceterm pinch",
        "deviceterm button",
        "deviceterm key",
        "deviceterm text",
        "deviceterm rotate",
        "deviceterm crown",
        "deviceterm ax tree",
        "deviceterm ax point",
        "deviceterm ax sweep"
    ]
    let prose = allTopicProse
    for example in verbsWithExamples {
        #expect(prose.contains(example), "missing example: \(example)")
    }
}

@Test
func helpCarriesCrownGuidance() {
    // The crown guidance is load-bearing:
    // single-shot for fine placement on tight bindings, --duration
    // for coarse scroll. The user-facing surface has to carry it so
    // an agent reading the crown page learns the gotcha before filing a
    // "deviceterm crown is broken" report.
    let crown = HelpCatalog.topic(named: "crown")?.detail ?? ""
    #expect(crown.contains("single-shot"))
    #expect(crown.contains("digitalCrownRotation"))
    #expect(crown.contains("coalescing floor"))
}

@Test
func helpCarriesCrownVelocityCaveat() {
    // `--velocity` is decoded but daemon-ignored, so agents who tune
    // it expecting effect get tripped up. The caveat must surface.
    let crown = HelpCatalog.topic(named: "crown")?.detail ?? ""
    #expect(crown.contains("velocity"))
    #expect(crown.contains("silently ignored at the daemon"))
}

@Test
func helpCarriesAXTreeEmptyPointer() {
    // `ax tree` returning empty on watchOS is a known limitation;
    // `ax sweep` is the workaround. The help has to surface that.
    let axDetail = HelpCatalog.topic(named: "ax")?.detail ?? ""
    #expect(axDetail.contains("ax sweep"))
    #expect(axDetail.contains("workaround"))
}

@Test
func helpCarriesSwipeTapPromotionNote() {
    // The swipe ack: a swipe < 32 ms collapses to a tap-shape and
    // surfaces `dispatched=tap`. Agents need to know this.
    #expect(HelpCatalog.topic(named: "swipe")?.detail.contains("dispatched=tap") == true)
}

@Test
func helpPointsAtDeviceTermAgents() {
    // `deviceterm agents` is the longer-form triage surface; the help
    // should point at it so an agent who needs more depth knows
    // where to look.
    #expect(allTopicProse.contains("deviceterm agents"))
    #expect(HelpText.overview.contains("deviceterm agents"))
}

@Test
func helpDescribesPaneDisambiguation() {
    // The `--pane` story is shared by every pane-targeted command, so it
    // gets one topic instead of being repeated across verbs.
    #expect(HelpCatalog.topic(named: "targeting")?.detail.contains("--pane") == true)
}

@Test
func helpScopesJSONClaimToDataCommands() {
    // Regression guard: the output topic must scope --json support to data commands
    // (lists, receipts), because documentation commands (--help, agents)
    // are deliberately text-only. The carve-out has to be
    // explicit so a future copy-edit doesn't re-broaden into a
    // contradiction with runtime behavior.
    let output = HelpCatalog.topic(named: "output")?.detail ?? ""
    #expect(output.contains("Data commands"))
    #expect(output.contains("remain prose"))
}

@Test
func helpDescribesTypedJSONFailures() {
    let output = HelpCatalog.topic(named: "output")?.detail ?? ""
    #expect(output.contains("typed failures"))
    #expect(output.contains("`error.code`"))
    #expect(output.contains("`error` envelope even without `--json`"))
    #expect(output.contains("JSON Lines stream"))
}

@Test
func helpLineWidthFitsInEightyCols() {
    // Terminal-friendly readability. We aim for 78 chars or fewer
    // per line so an 80-col terminal renders without wrap. A
    // tolerance is acceptable; hard cap is 80 for any single line.
    var surfaces = [HelpText.overview]
    surfaces += HelpCatalog.topicNames.compactMap { HelpText.page(forTopic: $0) }
    for surface in surfaces {
        for (index, line) in surface.split(separator: "\n").enumerated() {
            #expect(line.count <= 80, "line \(index + 1) is \(line.count) chars: \(line)")
        }
    }
}
