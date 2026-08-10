// SPDX-License-Identifier: GPL-3.0-or-later
//
// PaneChromeDragHostView: AppKit drag source wrapper around a
// pane's chrome strip. Hosts the SwiftUI chrome via `NSHostingView`,
// catches mouseDown / mouseDragged on the strip, and emits a pane
// drag with a translucent snapshot of the entire pane as the drag
// image so the pane visibly lifts with the pointer.
//
// The drag payload (`PaneDragPayload`, tabID + slot) is encoded as
// JSON onto the pasteboard; the `PaneLayoutViewController` drag
// destination decodes it on entry/drop. Cross-window and cross-tab
// drags are rejected destination-side so a mistaken drop never
// re-parents a session.

import AppKit
import SwiftUI

@MainActor
final class PaneChromeDragHostView<Content: View>: NSView, NSDraggingSource {
    /// The tab id this chrome's pane belongs to, carried on the
    /// pasteboard payload so the destination can reject drops from
    /// other tabs.
    var tabID: TabID?
    /// The pane's slot, the same payload field. The slot identifies which
    /// leaf of the tree is being dragged.
    var slot: PaneSlot?
    /// View whose snapshot becomes the drag image. Typically the
    /// pane's wrapper view (chrome + content), so the user drags a
    /// translucent miniature of the whole pane.
    weak var snapshotSource: NSView?
    /// View that should become first responder when the chrome strip
    /// is clicked. Sim panes wire it to the wrapper (which forwards
    /// to the Metal content view via its `inputTarget`); terminal
    /// panes wire it to libghostty's surface view directly. Without
    /// this, a click on the chrome would never propagate focus to
    /// the pane and the focus border would refuse to light up.
    weak var focusReceiver: NSView?

    private let hosting: PaneChromeHostingView<Content>
    private let showsGrabCursor: Bool
    private var mouseDownPoint: CGPoint?

    /// Build the drag host wrapper around a SwiftUI chrome surface.
    /// `showsGrabCursor` toggles the openHand cursor rect over the
    /// wrapper bounds: appropriate for the terminal chrome's compact
    /// title strip (no buttons under the chrome bar) but distracting
    /// over the sim chrome where every region of the strip already
    /// hosts interactive hardware-button or control rows. When false,
    /// the standard arrow cursor stays visible on hover; the
    /// closedHand cursor still pushes for the active drag session.
    init(rootView: Content, showsGrabCursor: Bool = true) {
        self.hosting = PaneChromeHostingView(rootView: rootView)
        self.showsGrabCursor = showsGrabCursor
        super.init(frame: .zero)
        wantsLayer = true
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        if showsGrabCursor {
            addCursorRect(bounds, cursor: .openHand)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    func updateRootView(_ rootView: Content) {
        hosting.rootView = rootView
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if showsGrabCursor {
            addCursorRect(bounds, cursor: .openHand)
        }
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        // Activate focus on this pane on any chrome click: the focus
        // border + per-pane interaction state both key off the
        // window's first responder, and the SwiftUI chrome buttons
        // forward their hits without changing it. Without this,
        // clicking the strip would never light up the pane's focus
        // border.
        if let receiver = focusReceiver, receiver.window != nil {
            window?.makeFirstResponder(receiver)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint,
            let tabID,
            let slot else { return }
        let current = convert(event.locationInWindow, from: nil)
        let deltaX = current.x - start.x
        let deltaY = current.y - start.y
        guard hypot(deltaX, deltaY) >= 4 else { return }
        mouseDownPoint = nil
        beginDragSession(event: event, tabID: tabID, slot: slot)
    }

    private func beginDragSession(event: NSEvent, tabID: TabID, slot: PaneSlot) {
        let payload = PaneDragPayload(tabID: tabID, slot: slot)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let item = NSPasteboardItem()
        item.setData(data, forType: NSPasteboard.PasteboardType(PaneDragPayload.pasteboardType))
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let snapshot = renderSnapshot()
        let imageSize = snapshot.size
        draggingItem.setDraggingFrame(
            CGRect(origin: convert(event.locationInWindow, from: nil), size: imageSize),
            contents: snapshot
        )
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    private func renderSnapshot() -> NSImage {
        let source = snapshotSource ?? self
        guard let rep = source.bitmapImageRepForCachingDisplay(in: source.bounds) else {
            return NSImage(size: .init(width: 1, height: 1))
        }
        source.cacheDisplay(in: source.bounds, to: rep)
        let scaled = NSImage(size: NSSize(width: rep.size.width * 0.6, height: rep.size.height * 0.6))
        scaled.addRepresentation(rep)
        return scaled
    }

    // MARK: - NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(
        _ session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint
    ) {
        NSCursor.closedHand.push()
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        NSCursor.pop()
    }
}

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
