// SPDX-License-Identifier: GPL-3.0-or-later

/// A device lying flat, as a `pane.input.rotate` target.
///
/// Used in rotation requests and results, never as a pane's display
/// orientation. Raw values match UIKit's `UIDeviceOrientation` names, as
/// `Orientation`'s do. A device laid flat keeps the interface orientation it
/// had, so a pane never reports one of these as its orientation and
/// `Orientation` stays the four a display can show.
public enum FlatOrientation: String, Codable, Sendable, Equatable, CaseIterable {
    case faceUp
    case faceDown
}
