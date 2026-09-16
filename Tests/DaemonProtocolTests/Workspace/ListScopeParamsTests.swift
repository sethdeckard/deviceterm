// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import Testing

// `all` is optional on the wire for both listing verbs. An omitted key selects
// the scoped listing, which preserves older pane-list callers and keeps
// tab-list decoding tolerant of a request built by hand.

@Test
func listTabsDefaultsToTheScopedListingWhenAllIsAbsent() throws {
    let wire = Data(#"{"window":"main"}"#.utf8)
    let decoded = try JSONDecoder().decode(AppCommandParams.ListTabs.self, from: wire)

    #expect(decoded == AppCommandParams.ListTabs(window: "main", all: false))
    #expect(!decoded.all)
}

@Test
func listPanesDefaultsToTheScopedListingWhenAllIsAbsent() throws {
    let wire = Data(#"{"tab":"auth"}"#.utf8)
    let decoded = try JSONDecoder().decode(AppCommandParams.ListPanes.self, from: wire)

    #expect(decoded == AppCommandParams.ListPanes(tab: "auth", all: false))
    #expect(!decoded.all)
}

/// A request naming no object at all is the common shape, since both verbs
/// default to the caller's own window or tab.
@Test
func listParamsDecodeAnEmptyRequest() throws {
    let empty = Data(#"{}"#.utf8)

    #expect(
        try JSONDecoder().decode(AppCommandParams.ListTabs.self, from: empty)
            == AppCommandParams.ListTabs(window: nil, all: false)
    )
    #expect(
        try JSONDecoder().decode(AppCommandParams.ListPanes.self, from: empty)
            == AppCommandParams.ListPanes(tab: nil, all: false)
    )
}

@Test("round-trips an explicit all", arguments: [true, false])
func listParamsRoundTripAll(all: Bool) throws {
    let tabs = AppCommandParams.ListTabs(window: nil, all: all)
    let panes = AppCommandParams.ListPanes(tab: nil, all: all)

    #expect(
        try JSONDecoder().decode(
            AppCommandParams.ListTabs.self,
            from: JSONEncoder().encode(tabs)
        ) == tabs
    )
    #expect(
        try JSONDecoder().decode(
            AppCommandParams.ListPanes.self,
            from: JSONEncoder().encode(panes)
        ) == panes
    )
}

/// The flag has to reach the wire, or the tolerant decode above would mask a
/// request that never carried it.
@Test
func listParamsEncodeAllOnTheWire() throws {
    let tabs = try JSONEncoder().encode(AppCommandParams.ListTabs(window: nil, all: true))
    let panes = try JSONEncoder().encode(AppCommandParams.ListPanes(tab: nil, all: true))

    #expect(try #require(String(bytes: tabs, encoding: .utf8)).contains("\"all\":true"))
    #expect(try #require(String(bytes: panes, encoding: .utf8)).contains("\"all\":true"))
}
