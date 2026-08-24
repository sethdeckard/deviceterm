// SPDX-License-Identifier: GPL-3.0-or-later
//
// PaneOperation: the verb vocabulary pane errors report.
//
// `PaneError.bridgeFailed` and `.unsupportedOperation` both name the verb
// that failed, and that name reaches the user: `PaneMethods.mapPaneError`
// folds it into an RPC error message, and `diagnosticKind` folds it into a
// log line. It is a closed set the daemon owns, so it is a type rather than
// a string literal repeated at every throw site.
//
// The labels are load-bearing text, not identifiers. Clients read them in
// error messages, so `label` is the contract; renaming a case is free,
// changing its label is not.

import DaemonProtocol

/// A verb a pane-targeted operation can fail under, as reported by
/// `PaneError`.
///
/// Most cases are fixed. `button` carries its `HardwareButton` so a failed
/// press names the button rather than the generic verb, and the two
/// `*Acquire` cases name client acquisition specifically, which is a
/// different failure from the operation that acquisition was for.
public enum PaneOperation: Sendable, Equatable {
    case tap
    case touch
    case edgeTouch
    case swipe
    case edgeSwipe
    case longPress
    case keyDown
    case keyUp
    case button(HardwareButton)
    case pinch
    case multitouch
    case text
    case rotate
    case crown
    case axTree
    case axPoint
    case axSweep
    /// Accessibility *client* acquisition, as distinct from the tree/point/
    /// sweep read it was acquired for.
    case axAcquire
    case locationSet
    /// Location *client* acquisition, the location counterpart to
    /// `axAcquire`.
    case locationAcquire
    /// Reading the device's available scenarios, the only operation that can
    /// report unintelligible output.
    case locationEnumerate

    /// The text this verb contributes to an error message or log line.
    ///
    /// Every value here is user-visible, so these strings are fixed. A change
    /// to one is a change to what clients read.
    public var label: String {
        switch self {
        case .tap:
            return "tap"

        case .touch:
            return "touch"

        case .edgeTouch:
            return "edgeTouch"

        case .swipe:
            return "swipe"

        case .edgeSwipe:
            return "edgeSwipe"

        case .longPress:
            return "longPress"

        case .keyDown:
            return "keyDown"

        case .keyUp:
            return "keyUp"

        case let .button(button):
            return "button.\(button.rawValue)"

        case .pinch:
            return "pinch"

        case .multitouch:
            return "multitouch"

        case .text:
            return "text"

        case .rotate:
            return "rotate"

        case .crown:
            return "crown"

        case .axTree:
            return "ax.tree"

        case .axPoint:
            return "ax.point"

        case .axSweep:
            return "ax.sweep"

        case .axAcquire:
            return "ax.acquire"

        case .locationSet:
            return "location.set"

        case .locationAcquire:
            return "location.acquire"

        case .locationEnumerate:
            return "location.enumerate"
        }
    }

    /// The key-event verb for a press or release, so callers translate the
    /// direction once rather than at each throw site.
    static func key(down: Bool) -> PaneOperation {
        down ? .keyDown : .keyUp
    }
}
