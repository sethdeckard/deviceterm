// SPDX-License-Identifier: GPL-3.0-or-later
//
// PaneLifecycle: a sim pane's lifecycle state, shared between the
// daemon (which owns the transitions) and the GUI client (which renders
// them). Lives in DaemonProtocol so both sides spell the states once;
// the rawValue is the wire string carried by the `state.changed` event
// and the `panes.list` row (own-contract enum: strict decode, bump
// `wireVersion` to add a case; see the Wire-compatibility policy).

public enum PaneLifecycle: String, Sendable, Codable, Equatable {
    case booting
    case rendering
    case shutdown
    case failed
}
