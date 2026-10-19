// SPDX-License-Identifier: GPL-3.0-or-later

/// `pane.subscribe` event `panel.changed`. Names the panel a foldable pane is
/// showing, replayed to a new subscriber once a panel has been observed.
///
/// Published whenever the lit panel moves, and only for a device with more
/// than one panel. Independent of the hinge angle: which panel is lit is known
/// as soon as the display binds, whether or not anything can read the hinge.
public struct PanelChangedEvent: Codable, Sendable, Equatable {
    public let paneId: String
    /// The panel's small integer id, the value `simctl io --display` accepts.
    /// Absent when the display proxy reports no screen properties.
    public let screenID: UInt32?
    /// Whether the panel is the one the hinge runs through, so its picture
    /// bends as the angle changes. False for a foldable's cover panel.
    public let spansHinge: Bool
    /// The pixel size of the panel that spans the hinge, whichever panel is
    /// showing, so a subscriber can draw both panels at one scale and tell
    /// which panel a frame came from by its size. Both present or both
    /// absent: absent when the daemon can't size the panels. Optional so
    /// events from peers that omit these fields still decode.
    public let spanningPanelWidth: Int?
    public let spanningPanelHeight: Int?

    public init(
        paneId: String,
        screenID: UInt32?,
        spansHinge: Bool,
        spanningPanelWidth: Int? = nil,
        spanningPanelHeight: Int? = nil
    ) {
        self.paneId = paneId
        self.screenID = screenID
        self.spansHinge = spansHinge
        self.spanningPanelWidth = spanningPanelWidth
        self.spanningPanelHeight = spanningPanelHeight
    }
}
