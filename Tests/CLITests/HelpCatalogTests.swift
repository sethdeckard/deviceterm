// SPDX-License-Identifier: GPL-3.0-or-later

@testable import DeviceTermCLI
import Foundation
import Testing

// Drift guards joining `HelpCatalog` to the two tables it has to agree
// with: `VerbCatalog` (parser grammar + completion sub-verbs) and the
// `CLICommand` parse switch itself.
//
// These join catalog structure to those tables and check the prose
// invariants that structure depends on: that a verb can't gain a parser
// entry without gaining a page, that a page can't outlive the verb it
// documents, that a sub-verb the completion scripts offer is one the
// help actually explains, and that a summary stays safe to interpolate
// into a generated shell script.

@Test
func everyVerbHasATopicAndEveryTopicHasAVerb() {
    let verbs = Set(VerbCatalog.all.map(\.name))
    let documented = Set(HelpCatalog.commandNames)
    let undocumented = verbs.subtracting(documented).sorted()
    let orphaned = documented.subtracting(verbs).sorted()
    #expect(undocumented.isEmpty, "verbs with no help topic: \(undocumented)")
    #expect(orphaned.isEmpty, "help topics naming no verb: \(orphaned)")
}

@Test
func everyCommandTopicNamesARealParsedVerb() {
    // The catalog-to-parser guard. A recognized verb parses to something
    // other than the unknown-verb sentinel: either a real command, or a
    // usage error carrying a message. Only an unrecognized verb reaches
    // `.usage(message: nil)`, which makes this exact without reflection.
    for name in HelpCatalog.commandNames {
        let parsed = CLICommands.parse(["deviceterm", name])
        #expect(
            parsed != .usage(message: nil),
            "help documents '\(name)', which the parser does not recognize"
            )
    }
}

@Test
func everySubVerbAppearsInItsParentTopic() {
    // A sub-verb the completion scripts offer but the help never
    // explains is a verb users can tab-complete into and then have to
    // guess at.
    for verb in VerbCatalog.all where !verb.subVerbs.isEmpty {
        let detail = HelpCatalog.topic(named: verb.name)?.detail ?? ""
        for sub in verb.subVerbs {
            #expect(
                detail.contains("\(verb.name) \(sub)"),
                "'\(verb.name) \(sub)' is missing from the \(verb.name) page"
                )
        }
    }
}

@Test
func topicNamesAreUniqueAndNonEmpty() {
    // `HelpCatalog.byName` is built with `uniqueKeysWithValues`, which
    // traps on a duplicate. Failing here names the collision instead.
    var seen: Set<String> = []
    for topic in HelpCatalog.topics {
        #expect(!topic.name.isEmpty, "topic with an empty name")
        #expect(seen.insert(topic.name).inserted, "duplicate topic name: \(topic.name)")
    }
}

@Test
func summariesFitTheOverviewColumn() {
    // Length keeps the column aligned inside 80 chars. The two character
    // bans have separate causes: an apostrophe closes the single-quoted
    // string the summary is interpolated into, yielding a completion
    // script that fails to load at shell startup; a colon is zsh
    // `_describe`'s name/description separator, so one in a summary
    // silently truncates the gloss.
    for topic in HelpCatalog.topics {
        #expect(!topic.summary.isEmpty, "\(topic.name) has no summary")
        #expect(
            topic.summary.count <= 60,
            "\(topic.name) summary is \(topic.summary.count) chars"
            )
        #expect(!topic.summary.contains("\n"), "\(topic.name) summary spans lines")
        #expect(!topic.summary.contains(":"), "\(topic.name) summary contains a colon")
        #expect(!topic.summary.contains("'"), "\(topic.name) summary contains an apostrophe")
        #expect(
            topic.summary.trimmingCharacters(in: .whitespaces) == topic.summary,
            "\(topic.name) summary has surrounding whitespace"
            )
    }
}

@Test
func detailsCarryNoTrailingNewline() {
    // `page(forTopic:)` and the group-note join both assume it, so a
    // stray newline shows up as a blank line in rendered output.
    for topic in HelpCatalog.topics {
        #expect(
            !topic.detail.hasSuffix("\n"),
            "\(topic.name) detail has a trailing newline"
            )
        #expect(!topic.detail.isEmpty, "\(topic.name) has no detail")
    }
}

@Test
func suggestionsFindNearMissesAndStayQuietOtherwise() {
    #expect(HelpCatalog.suggestions(for: "cro") == ["crown"])
    #expect(HelpCatalog.suggestions(for: "window").contains("windows"))
    #expect(HelpCatalog.suggestions(for: "zzzz").isEmpty)
    #expect(HelpCatalog.suggestions(for: "").isEmpty)
    // Capped, so a broad prefix can't print the whole catalog.
    #expect(HelpCatalog.suggestions(for: "t").count <= 3)
}
