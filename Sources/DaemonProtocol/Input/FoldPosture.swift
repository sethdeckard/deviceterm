// SPDX-License-Identifier: GPL-3.0-or-later

/// The named hinge positions a foldable device is driven to.
///
/// The hinge is continuous, so the wire carries degrees and this names the
/// three positions worth a word. Defined once here rather than at the CLI
/// that parses them, so that any later caller resolves a name to the same
/// angle.
public enum FoldPosture: String, Codable, Sendable, CaseIterable {
    /// Folded shut, showing the cover panel.
    case closed
    /// Open far enough to use the inner panel while still bent.
    case book
    /// Flat.
    case open

    /// The lowest and highest angle the hinge accepts.
    public static let degreeRange: ClosedRange<Double> = 0...180

    /// Where this posture puts the hinge.
    ///
    /// `book` is not a measured reading of any control. 120 sits above the
    /// angle where opening has been seen to move the guest to the inner
    /// panel, with room to spare, because that boundary is not fixed.
    public var degrees: Double {
        switch self {
        case .closed:
            return 0

        case .book:
            return 120

        case .open:
            return 180
        }
    }

    /// The posture named by `text`, or nil when it names none. Callers that
    /// also accept a bare angle try this first and parse a number after.
    public static func named(_ text: String) -> FoldPosture? {
        FoldPosture(rawValue: text.lowercased())
    }
}
