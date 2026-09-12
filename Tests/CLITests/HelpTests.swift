// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
@testable import DeviceTermCLI
import Foundation
import Testing

// `deviceterm help` parsing + content invariants.
//
// Parser side: the three top-level triggers (`--help`, `-h`, `help`)
// resolve to `.help`. The topic is the longest declared command path the
// tail names, falling back to the first non-flag token for a verb the
// command tree does not declare.
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
    // A topic the command tree does not declare resolves to the first
    // non-flag token after the trigger. All three spellings agree.
    // Making `--help crown` behave differently from `help crown` would
    // be a trap, not a feature.
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
func parseHelpTopicResolvesTheLongestCommandPath() {
    // A sub-verb has its own page, so the topic is the whole path it
    // names rather than the parent it sits under.
    #expect(CLICommands.parse(["deviceterm", "help", "tab", "open"]) == .help(topic: "tab open"))
    // A trailing token that names nothing stops the walk.
    #expect(CLICommands.parse(["deviceterm", "help", "tab", "burn"]) == .help(topic: "tab"))
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
    // `--all` is a real flag on `window list`, so a reader who copies
    // the signature into a help request must still reach the page. The
    // rejection above applies only when no topic was named; otherwise
    // the documented "operands after the topic are ignored" rule wins.
    //
    // The topic is the longest command path the tail names, so this
    // lands on `window list` rather than its parent.
    #expect(
        CLICommands.parse(["deviceterm", "help", "window", "list", "--all"])
        == .help(topic: "window list")
        )
    #expect(
        CLICommands.parse(["deviceterm", "help", "window", "--all"])
        == .help(topic: "window")
        )
}

@Test
func parseTextDashDashHelpAsksForHelp() {
    // `--help` means help on every verb, including the one that types
    // arbitrary text: a verb whose help you cannot ask for the usual way
    // is a trap of its own. `deviceterm text -- --help` types the
    // literal string.
    #expect(
        CLICommands.parse(["deviceterm", "text", "--help"])
        == .help(topic: "text")
        )
    #expect(
        CLICommands.parse(["deviceterm", "text", "--", "--help"])
        == .text(pane: nil, text: "--help")
        )
}

@Test
func parseVerbTrailingDashDashHelpAsksForThatVerb() {
    // A trailing `--help` reaches the verb's own page, and the `help`
    // spelling reaches the same one.
    #expect(CLICommands.parse(["deviceterm", "crown", "--help"]) == .help(topic: "crown"))
    #expect(CLICommands.parse(["deviceterm", "help", "crown"]) == .help(topic: "crown"))
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
    // An unknown verb is refused rather than answered with the command
    // list, which would read as though it had worked.
    let parsed = CLICommands.parse(["deviceterm", "wat"])
    guard case let .usage(message) = parsed else {
        Issue.record("expected .usage for an unknown verb; got \(parsed)")
        return
    }
    #expect(message?.contains("wat") ?? false)
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
    for verb in CommandTree.all.map(\.name) {
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
    for subcommand in ["tab open", "pane send-input", "ax sweep", "tab list", "window list"] {
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

@Test
func paneHelpExplainsHowToSendDashedWordsLiterally() {
    // `pane send-input` types arbitrary text, so the page has to say how
    // to send a word the parser would otherwise claim as a flag.
    let detail = HelpCatalog.topic(named: "pane")?.detail ?? ""
    #expect(detail.contains("beginning with - is read as a flag"))
    #expect(detail.contains("to send such a word literally"))
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
    #expect(HelpText.page(forTopic: "tab")?.contains("Workspace refs are raw strings") == true)
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
    // GUI workspace refs and daemon-direct device targeting have different
    // candidate sets. Stating the workspace grammar unscoped would
    // contradict `help targeting`.
    let refs = HelpText.page(forTopic: "refs") ?? ""
    #expect(refs.contains("Workspace refs"))
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
        "window list [--all]",
        "window show [<window>]",
        "window open",
        "window focus [<window>]",
        "window close [<window>]",
        "tab list [--window <ref> | --all]",
        "tab show [<tab>]",
        "tab open [--window <ref>]",
        "tab close",
        "tab rename",
        "tab focus",
        "tab move",
        "tab protect",
        "tab unprotect",
        "pane list [--tab <ref>]",
        "pane show [<pane>]",
        "pane split [<pane>]",
        "pane focus [<pane>]",
        "pane close",
        "pane send-input <pane>",
        "pane capture-text <pane>",
        "device attach <ref>",
        "pane rename",
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
func workspaceRefsDocumentLiveProjectionResolution() {
    #expect(HelpCatalog.refsLegend.contains("resolved case-insensitively against the"))
    #expect(HelpCatalog.refsLegend.contains("live projection"))
    #expect(HelpCatalog.refsLegend.contains("exact short ID"))
    #expect(HelpCatalog.refsLegend.contains("exact unique name"))
    #expect(HelpCatalog.refsLegend.contains("Names match exactly, never by prefix"))
    #expect(HelpCatalog.refsLegend.contains("display-order metadata"))
    #expect(HelpCatalog.refsLegend.contains("terminal pane's full ID is its session ID"))
}

@Test
func tabHelpDefinesTheWorkspace() {
    let tab = HelpCatalog.topic(named: "tab")?.detail ?? ""
    #expect(tab.contains("A tab is the workspace"))
    #expect(tab.contains("terminal,\n  Simulator, and physical-device panes"))
    #expect(tab.contains("WorkspaceTab objects"))
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
func helpCarriesReusableAccessibilityCoordinates() {
    let axDetail = HelpCatalog.topic(named: "ax")?.detail ?? ""
    #expect(axDetail.contains("`normalizedCenter.x` and `.y`"))
    #expect(axDetail.contains("real preflight tree"))
    #expect(axDetail.contains("has no `normalizedCenter`"))
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
