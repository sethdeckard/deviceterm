// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// `NSHostingView` subclass that routes hits on non-interactive
/// SwiftUI content (title text, spacers, the chrome background)
/// back to the enclosing `PaneChromeDragHostView`. Without this the
/// hosting view sits on top of the entire chrome strip and consumes
/// every mouseDown for SwiftUI's internal handling, even when the
/// user clicked an empty region, so the drag handler never sees
/// the event and pane drag-to-rearrange fails to initiate.
///
/// Real interactive SwiftUI subviews (Button, Menu, the × / ⋯
/// controls) still receive their hits as before: SwiftUI's hit-test
/// returns the specific subview, not the bare host, so we forward
/// it through unchanged. Only hits that resolve to `self` (= the
/// hosting view itself, i.e. nobody interactive wanted them) get
/// redirected to the wrapper. `PaneChromeHitDecision` holds the
/// choice, including the `interactiveOverride` check that runs whether
/// SwiftUI answered `self` or nothing.
@MainActor
final class PaneChromeHostingView<Content: View>: NSHostingView<Content> {
    /// Region that keeps its hits even where SwiftUI reports nothing
    /// interactive under them. The closure is handed the point in this view's
    /// own coordinates, converted from the superview space `hitTest(_:)`
    /// delivers, together with this view's bounds, and answers whether the hit
    /// belongs to SwiftUI.
    ///
    /// The sim ribbon's resize handle needs this because it is driven by a
    /// gesture rather than a `Button`, and `super.hitTest` answers `self` for
    /// a gesture-only view, so the pass-through below would hand the handle's
    /// drag to the pane-rearrange host and lift the pane instead of resizing
    /// the ribbon. Bounds arrive as a parameter so the closure never has to
    /// capture the view.
    ///
    /// The fold bar's host claims its whole row the same way, because its
    /// slider track is another region SwiftUI answers `self` for. Left nil by
    /// every other chrome, which keeps the plain pass-through.
    var interactiveOverride: ((NSPoint, CGRect) -> Bool)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        let answer: PaneChromeHitDecision.SwiftUIAnswer
        if result == nil {
            answer = .none
        } else if result === self {
            answer = .host
        } else {
            answer = .subview
        }
        let outcome = PaneChromeHitDecision.resolve(
            swiftUI: answer,
            overrideClaims: interactiveOverride?(convert(point, from: superview), bounds) == true
        )
        switch outcome {
        case .forward:
            return result

        case .claim:
            return self

        case .passThrough:
            return superview

        case .decline:
            return nil
        }
    }
}
