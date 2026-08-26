// SPDX-License-Identifier: GPL-3.0-or-later

/// The table behind `deviceterm help`.
///
/// Assembly and lookup live here; the topic prose lives in the
/// `HelpCatalog+*.swift` files, grouped the way the overview groups it.
/// `HelpText` turns this table into the overview and the per-topic pages.
///
/// Topics are ordered group-major so a single array drives the overview
/// without a sort. `HelpCatalogTests` pins the invariants that keep the
/// table honest: every `VerbCatalog` verb has a topic and vice versa, every
/// command topic names a verb the parser actually recognizes, and every
/// sub-verb appears in its parent's page.
enum HelpCatalog {
    /// Every topic, group-major in `HelpTopic.Group.allCases` order, with
    /// the concepts last.
    static let topics: [HelpTopic] =
        driveTopics
        + hardwareTopics
        + inspectTopics
        + deviceTopics
        + workspaceTopics
        + setupTopics
        + docsTopics
        + conceptTopics

    static let byName: [String: HelpTopic] = Dictionary(
        uniqueKeysWithValues: topics.map { ($0.name, $0) }
    )

    /// Names that list in the overview, in overview order.
    static var commandNames: [String] {
        topics.filter { $0.group != nil }.map(\.name)
    }

    /// Names reachable only as `deviceterm help <name>`, in catalog order.
    static var conceptNames: [String] {
        topics.filter { $0.group == nil }.map(\.name)
    }

    /// Every addressable name, which is what shell completion offers
    /// after `help`.
    static var topicNames: [String] { topics.map(\.name) }

    static func topic(named name: String) -> HelpTopic? { byName[name] }

    /// The topics listing under `group`, in catalog order.
    static func topics(in group: HelpTopic.Group) -> [HelpTopic] {
        topics.filter { $0.group == group }
    }

    /// Near-misses for an unrecognized `deviceterm help <name>`, at most
    /// three, in catalog order.
    ///
    /// Prefix containment in either direction, falling back to a shared
    /// three-character opening. Only queries that missed reach here, so
    /// the cases worth catching are a truncation (`cro`), an overlong
    /// guess (`crownx`), and a shared-prefix slip (`crox`). Cheaper than
    /// pulling an edit-distance implementation into the CLI for one error
    /// path. A transposition like `crwon` finds nothing and falls back to
    /// the "run `deviceterm help`" line, which is a fine answer.
    static func suggestions(for query: String) -> [String] {
        let query = query.lowercased()
        guard !query.isEmpty else { return [] }
        let prefixed = topicNames.filter {
            $0.hasPrefix(query) || query.hasPrefix($0)
        }
        if !prefixed.isEmpty { return Array(prefixed.prefix(3)) }
        guard query.count >= 3 else { return [] }
        let opening = query.prefix(3)
        return Array(topicNames.filter { $0.hasPrefix(opening) }.prefix(3))
    }
}
