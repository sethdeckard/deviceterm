// SPDX-License-Identifier: GPL-3.0-or-later

/// Which panel a foldable's display is mirroring, and whether that panel is
/// the one the hinge runs through.
///
/// Both answers come from the same resolution inside the bridge, so they are
/// carried together: reading them separately would let a fold land between
/// the two reads and pair a new panel's id with the old panel's shape.
struct BoundPanel: Equatable, Sendable {
    /// The small integer `simctl io --display` accepts, or `0` when the
    /// display proxy vends no screen properties.
    let screenID: UInt32
    /// Whether the bound panel spans the hinge, so its picture bends as the
    /// hinge moves. False on every single-panel device, and false for a
    /// foldable's cover panel, which sits outside the fold and stays flat at
    /// every angle.
    ///
    /// The bridge answers by extent: a foldable's panels differ in size
    /// because the one that spans the hinge unfolds to roughly twice the
    /// other, so the larger panel is the one that bends.
    let spansHinge: Bool
}
