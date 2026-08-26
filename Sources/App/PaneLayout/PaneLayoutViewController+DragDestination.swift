// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// The pane drag-and-drop
/// reorder target, split out of the layout controller's hot file. The
/// controller's `PaneLayoutContainerView` forwards the NSView drag
/// callbacks here via a weak delegate; this reads the live tree +
/// pane-view frames, delegates the cursor→zone geometry to the pure
/// `PaneDropZoneMath`, paints the overlay, and dispatches
/// `Route.reorderPane` on drop. It never touches the ratio / split
/// hierarchy; the drop just re-emits a nav intent the Router owns.
extension PaneLayoutViewController {
    /// Reset the cached drag color for a fresh drag session.
    func refreshDropOverlayColor() {
        let base = GhosttyThemeColors.cachedSelectionBackground()
            ?? NSColor.controlAccentColor
        dropOverlayColor = base.withAlphaComponent(0.45)
    }

    func handleDraggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        refreshDropOverlayColor()
        return handleDraggingUpdated(sender)
    }

    func handleDraggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let payload = decodePayload(sender), payload.tabID == tabID else {
            removeDropOverlay()
            return []
        }
        let cursor = view.convert(sender.draggingLocation, from: nil)
        guard let (slot, zone) = hit(at: cursor), slot != payload.slot else {
            removeDropOverlay()
            return []
        }
        showOverlay(for: slot, zone: zone)
        return .move
    }

    func handleDraggingExited(_ sender: (any NSDraggingInfo)?) {
        removeDropOverlay()
    }

    func handlePerformDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let payload = decodePayload(sender), payload.tabID == tabID else {
            removeDropOverlay()
            return false
        }
        let cursor = view.convert(sender.draggingLocation, from: nil)
        guard let (target, zone) = hit(at: cursor), target != payload.slot else {
            removeDropOverlay()
            return false
        }
        removeDropOverlay()
        router?.dispatch(.reorderPane(
            tab: tabID,
            slot: payload.slot,
            target: target,
            zone: zone
        ))
        return true
    }

    private func decodePayload(_ sender: any NSDraggingInfo) -> PaneDragPayload? {
        guard let items = sender.draggingPasteboard.pasteboardItems else { return nil }
        let pbType = NSPasteboard.PasteboardType(PaneDragPayload.pasteboardType)
        for item in items {
            guard let data = item.data(forType: pbType) else { continue }
            if let payload = try? JSONDecoder().decode(PaneDragPayload.self, from: data) {
                return payload
            }
        }
        return nil
    }

    private func hit(at point: CGPoint) -> (PaneSlot, DropZone)? {
        for slot in PaneTreeOps.leavesInOrder(tree) {
            // A pending placeholder is about to be swapped out, so it is never a
            // drop target (and it's not a drag source either; it has no
            // drag host).
            if case .pending = slot { continue }
            guard let paneView = paneVCs[slot]?.view else { continue }
            let frame = view.convert(paneView.bounds, from: paneView)
            if let zone = PaneDropZoneMath.zone(forCursor: point, in: frame) {
                return (slot, zone)
            }
        }
        return nil
    }

    private func showOverlay(for slot: PaneSlot, zone: DropZone) {
        guard let paneView = paneVCs[slot]?.view else { return }
        let frame = view.convert(paneView.bounds, from: paneView)
        let overlayFrame = overlayRect(for: zone, in: frame)
        let layer = dropOverlayLayer ?? CALayer()
        layer.backgroundColor = dropOverlayColor.cgColor
        layer.cornerRadius = 4
        layer.frame = overlayFrame
        if layer.superlayer == nil {
            view.wantsLayer = true
            view.layer?.addSublayer(layer)
        }
        dropOverlayLayer = layer
    }

    private func removeDropOverlay() {
        dropOverlayLayer?.removeFromSuperlayer()
        dropOverlayLayer = nil
    }

    private func overlayRect(for zone: DropZone, in frame: CGRect) -> CGRect {
        switch zone {
        case .center:
            return frame.insetBy(dx: frame.width * 0.2, dy: frame.height * 0.2)

        case .leftHalf:
            return CGRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height)

        case .rightHalf:
            return CGRect(
                x: frame.midX,
                y: frame.minY,
                width: frame.width / 2,
                height: frame.height
            )

        case .topHalf:
            return CGRect(
                x: frame.minX,
                y: frame.midY,
                width: frame.width,
                height: frame.height / 2
            )

        case .bottomHalf:
            return CGRect(
                x: frame.minX,
                y: frame.minY,
                width: frame.width,
                height: frame.height / 2
            )
        }
    }
}

/// Root container view for the layout controller. Forwards drag
/// destination callbacks to the controller via a weak delegate so
/// the controller, not the view, owns the drag-state logic.
@MainActor
final class PaneLayoutContainerView: NSView {
    weak var dragDelegate: PaneLayoutViewController?

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dragDelegate?.handleDraggingEntered(sender) ?? []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dragDelegate?.handleDraggingUpdated(sender) ?? []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dragDelegate?.handleDraggingExited(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dragDelegate?.handlePerformDragOperation(sender) ?? false
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        true
    }
}
