// SPDX-License-Identifier: GPL-3.0-or-later

/// Which panel a foldable's display is mirroring, and whether that panel is
/// the one the hinge runs through.
///
/// Both answers come from the same resolution inside the bridge, so they are
/// carried together: reading them separately would let a fold land between
/// the two reads and pair a new panel's id with the old panel's shape.
public struct BoundPanel: Equatable, Sendable {
    /// The small integer `simctl io --display` accepts, or `0` when the
    /// display proxy vends no screen properties.
    public let screenID: UInt32
    /// Whether the bound panel spans the hinge, so its picture bends as the
    /// hinge moves. False on every single-panel device, and false for a
    /// foldable's cover panel, which sits outside the fold and stays flat at
    /// every angle.
    ///
    /// The bridge answers by extent: a foldable's panels differ in size
    /// because the one that spans the hinge unfolds to roughly twice the
    /// other, so the larger panel is the one that bends.
    public let spansHinge: Bool
    /// The pixel size of the panel that spans the hinge, whichever panel is
    /// bound, so a subscriber can draw either panel at the same scale and tell
    /// a frame's panel from its size. Zero when unknown, and on every
    /// single-panel device.
    public let spanningPanelWidth: Int
    public let spanningPanelHeight: Int
    /// The panel's stable identifier, the display UUID the simulator's HID
    /// daemon names its touchscreens by. Nil when the proxy vends none.
    public let uniqueID: String?

    public init(
        screenID: UInt32,
        spansHinge: Bool,
        spanningPanelWidth: Int = 0,
        spanningPanelHeight: Int = 0,
        uniqueID: String? = nil
    ) {
        self.screenID = screenID
        self.spansHinge = spansHinge
        self.spanningPanelWidth = spanningPanelWidth
        self.spanningPanelHeight = spanningPanelHeight
        self.uniqueID = uniqueID
    }
}
