// SPDX-License-Identifier: GPL-3.0-or-later
//
// HelpTopic: one addressable page of the `deviceterm help` surface.
//
// A topic is either a command (one overview line under its group, plus a
// full page at `deviceterm help <verb>`) or a concept (a page, named in the
// overview footer, with no overview line of its own). `HelpCatalog` holds
// the table; `HelpText` renders it.
//
// The split from `VerbCatalog` is deliberate: that table is parser grammar
// (which flags take a value, which sub-verbs a verb accepts) and is read on
// every flag split. Prose belongs beside prose. `HelpCatalogTests` joins the
// two so a verb can't gain a parser entry without gaining a page.

struct HelpTopic: Sendable, Equatable {
    /// Where the topic surfaces. `.command` topics occupy an overview line
    /// under their group; `.concept` topics are reachable only by name.
    enum Placement: Sendable, Equatable {
        case command(Group)
        case concept
    }

    /// Overview section order. `allCases` is the order sections print in,
    /// and topics within a section print in catalog order. Sequenced by the
    /// work rather than by subsystem: driving a device comes first because
    /// a pane usually arrives on its own, from booting a sim or mirroring a
    /// device, so the roster and attach verbs are a recovery path.
    enum Group: Sendable, CaseIterable {
        case drive
        case hardware
        case inspect
        case devices
        case workspace
        case setup
        case docs

        var title: String {
            switch self {
            case .drive:
                "Drive the device"

            case .hardware:
                "Hardware input"

            case .inspect:
                "Inspect"

            case .devices:
                "Devices"

            case .workspace:
                "Manage the workspace"

            case .setup:
                "Setup and health"

            case .docs:
                "Docs"
            }
        }

        /// A short parenthetical printed beside the section title in the
        /// overview. Context that qualifies every member of the group.
        var titleAside: String? {
            switch self {
            case .drive:
                "coords are normalized to what's on screen; (0,0) top-left"

            case .workspace:
                "back-channel verbs"

            default:
                nil
            }
        }

        /// Context every member of the group needs, appended to each
        /// member's page. Without this a reader who lands on `help tap`
        /// never learns the coordinate convention, and one on `help tab`
        /// never learns what `--tab` accepts.
        var note: String? {
            switch self {
            case .drive:
                "  Coords are normalized to what the device is showing:\n"
                    + "  (0,0) top-left, (1,1) bottom-right. A Simulator's\n"
                    + "  observed rotation is followed; a physical device is\n"
                    + "  assumed portrait until deviceterm rotates it.\n"
                    + HelpCatalog.paneTargetNote

            case .hardware, .inspect:
                HelpCatalog.paneTargetNote

            case .workspace:
                HelpCatalog.refsLegend

            default:
                nil
            }
        }
    }

    /// Lookup key for `deviceterm help <name>`. A `.command` topic's name
    /// equals its `VerbCatalog` entry's name; `HelpCatalogTests` enforces
    /// that the two sets match exactly.
    let name: String
    let placement: Placement
    /// The overview's right-hand column. Sentence case, no trailing
    /// period, and two character bans with separate causes: an apostrophe
    /// would close the single-quoted string this is interpolated into,
    /// producing a completion script that fails to load; a colon is the
    /// separator in a zsh `_describe` `name:description` pair, so one
    /// here silently truncates the gloss.
    let summary: String
    /// The reference block `deviceterm help <name>` prints: indented,
    /// wrapped to 78 columns, carrying its own signature line, with no
    /// section header and no trailing newline.
    let detail: String

    /// The group a `.command` topic lists under; nil for a concept.
    var group: Group? {
        switch placement {
        case let .command(group):
            group

        case .concept:
            nil
        }
    }

    init(_ name: String, _ placement: Placement, summary: String, detail: String) {
        self.name = name
        self.placement = placement
        self.summary = summary
        self.detail = detail
    }
}
