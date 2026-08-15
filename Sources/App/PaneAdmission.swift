// SPDX-License-Identifier: GPL-3.0-or-later
//
// PaneAdmission: which admission of a pane a close is talking about.
//
// A re-attach does not mint a new pane. The daemon keeps the existing record
// and its id, and on a revisioned re-attach bumps only its `attachment`
// (`PaneCoordinator.attach`). So a paneId can outlive the admission a caller
// captured, and paneId alone cannot say whether the pane in hand is still
// the one a decision was made about. The pair can.
//
// The daemon enforces the same pairing from its side: `pane.close` carrying
// `expecting` is refused when the record has moved on. This type is the GUI
// half, so a close the user was asked about is fenced before it is sent as
// well as when it arrives.

/// A pane id together with the admission it was observed under. Nil
/// `attachment` comes from a daemon predating the field, which closes
/// unconditionally.
struct PaneAdmission: Hashable, Sendable {
    let paneId: String
    let attachment: UInt64?
}

extension MirroredPaneState {
    var admission: PaneAdmission {
        PaneAdmission(paneId: paneId, attachment: attachment)
    }
}
