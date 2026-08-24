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
/// redirected to the wrapper.
@MainActor
final class PaneChromeHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        if result === self {
            return superview
        }
        return result
    }
}
