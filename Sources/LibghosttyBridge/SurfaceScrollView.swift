// SPDX-License-Identifier: GPL-3.0-or-later
//
// SurfaceScrollView: `NSScrollView` wrapper around a libghostty
// surface view so the host can paint a native macOS scrollbar
// reflecting libghostty's scrollback state.
//
// Architecture (matches Ghostty.app's SurfaceScrollView):
//
//   - `scrollView`:   outermost `NSScrollView`; renders the scroller
//                     and owns the clip view that posts bounds-change
//                     notifications.
//   - `documentView`: blank `NSView`; height sized to
//                     `total rows × cell height` so the scroller
//                     reflects the full scrollback geometry.
//   - `surfaceView`:  libghostty's render+input view (passed in by
//                     the host); positioned to fill the current
//                     visible rect so the renderer only draws the
//                     viewport.
//
// The wrapper provides bidirectional scrollbar sync:
//   1. Engine → host: `updateScrollbar(_:)` is called from the
//      `TerminalSurfaceDelegate.didUpdateScrollbar` path; it caches
//      the snapshot, resizes the document view, and (unless the
//      user is mid-drag) repositions the clip view to libghostty's
//      reported viewport offset.
//   2. Host → engine: the clip view posts bounds-change
//      notifications during user-driven scroll; the wrapper converts
//      the new origin to a row index and calls the
//      `scrollToRow` closure. A `lastSentRow` guard avoids
//      re-emitting when the user drags within the same row (an
//      action spam class the upstream code also guards against).
//
// `safeAreaInsets` is zeroed because hidden-titlebar window styles
// otherwise reserve a strip the terminal grid can't draw into. The
// content view's `clipsToBounds = false` follows Ghostty.app's
// pattern so a future legacy-style scroller doesn't cover the
// underlying terminal background.

import AppKit
import TerminalSurface

@MainActor
public final class SurfaceScrollView: NSView {
    /// Zero insets so a hidden-titlebar window style doesn't carve
    /// out a strip the terminal grid can't draw into. Matches
    /// Ghostty.app's SurfaceScrollView.
    override public var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }

    private let scrollView: NSScrollView
    private let documentView: NSView
    private let surfaceView: NSView
    private let cellHeightProvider: () -> CGFloat
    private let scrollToRow: (Int) -> Void

    /// The latest engine-reported scrollback state. Updated via
    /// `updateScrollbar(_:)` and read by `synchronizeScrollView()`
    /// during `layout()` so a freshly laid out view honours the
    /// most recent snapshot.
    private var scrollbar: ScrollbarState = .empty
    /// The last row we sent via `scroll_to_row`. Avoids re-emitting
    /// during a drag that stays inside one row (the
    /// `lastSentRow` guard, ported from Ghostty.app's
    /// `SurfaceScrollView.handleLiveScroll`).
    private var lastSentRow: Int?
    /// True between `willStartLiveScrollNotification` and
    /// `didEndLiveScrollNotification`. While true,
    /// `synchronizeScrollView` skips programmatic origin changes so
    /// the host doesn't fight the user's drag.
    private var isLiveScrolling = false
    private var observers: [NSObjectProtocol] = []

    /// `surfaceView` is the libghostty render+input view (typically
    /// `GhosttyTerminalSurface.view`). The wrapper takes over its
    /// embedding; callers must not also add it as a subview
    /// elsewhere.
    ///
    /// `cellHeightProvider` returns the engine's current cell height
    /// in points; closures (rather than a stored value) because the
    /// metric changes when the font / display scale changes and the
    /// host already owns that observation.
    ///
    /// `scrollToRow` is invoked when the user drags the scroller:
    /// the wrapper computes the target row from the clip-view
    /// origin and the host (typically
    /// `GhosttyTerminalSurface.scroll(toRow:)`) dispatches into the
    /// engine.
    public init(
        surfaceView: NSView,
        cellHeightProvider: @escaping () -> CGFloat,
        scrollToRow: @escaping (Int) -> Void
    ) {
        self.surfaceView = surfaceView
        self.cellHeightProvider = cellHeightProvider
        self.scrollToRow = scrollToRow
        self.scrollView = NSScrollView()
        self.documentView = NSView()
        super.init(frame: .zero)

        // The scroll view is the only child of this wrapper; it
        // controls all scroller rendering + behavior.
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.usesPredominantAxisScrolling = true
        // Overlay style throughout, so the wrapper never reserves
        // horizontal space for a legacy scroller. The hover flash for
        // a legacy system pref is handled below, in
        // `updateTrackingAreas` + `mouseMoved`.
        scrollView.scrollerStyle = .overlay
        // libghostty paints the terminal background itself; the
        // scroll view should not double-fill with system gray.
        scrollView.drawsBackground = false
        // Don't clip subviews of the clip view so a non-overlay
        // scroller wouldn't hide the terminal background underneath
        // (only overlay is used, but the config is correct
        // either way).
        scrollView.contentView.clipsToBounds = false

        // Document view is a blank NSView the scroll view scrolls;
        // the surface sits inside it, repositioned in
        // `synchronizeSurfaceView` to fill the visible rect.
        scrollView.documentView = documentView
        documentView.addSubview(surfaceView)

        addSubview(scrollView)

        installObservers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    deinit {
        // MainActor: `init` populated `observers`, so we're tearing
        // down on the same actor that registered them. The runtime
        // sequences `deinit` after the last reference, and AppKit
        // VCs / views drop their child on the main thread, so this
        // is safe.
        MainActor.assumeIsolated {
            for token in observers {
                NotificationCenter.default.removeObserver(token)
            }
        }
    }

    /// The engine reported a new scrollback snapshot. The host
    /// `TerminalSurfaceDelegate` dispatches into this so the wrapper
    /// can resize the document + reposition the viewport. Safe to
    /// call repeatedly; the `synchronizeScrollView` math is
    /// idempotent for equal snapshots.
    public func updateScrollbar(_ state: ScrollbarState) {
        scrollbar = state
        synchronizeScrollView()
    }

    /// The engine reported a new terminal background color. Switch
    /// the scroller appearance so the overlay scroller contrasts
    /// against the terminal background: light bg gets `.aqua`
    /// (dark scroller), dark bg gets `.darkAqua` (light scroller).
    /// Before this fires, `scrollView.appearance` stays nil so the
    /// scroller follows the system appearance (the safe default
    /// for the default Ghostty dark theme on most users' Macs).
    public func updateBackgroundColor(_ color: TerminalBackgroundColor) {
        let isLight = ColorLuma.isLight(
            red: color.red,
            green: color.green,
            blue: color.blue
        )
        scrollView.appearance = NSAppearance(
            named: isLight ? .aqua : .darkAqua
        )
    }

    override public func layout() {
        super.layout()
        scrollView.frame = bounds
        // Document view width tracks the scroll view; height comes
        // from `synchronizeScrollView` which knows about the latest
        // scrollbar state + cell metrics.
        documentView.frame.size.width = scrollView.bounds.width
        synchronizeScrollView()
        synchronizeSurfaceView()
    }

    // MARK: - Sync

    /// Resize the document view to reflect the scrollback total +
    /// (when not actively scrolling) seek the clip view to the
    /// engine-reported viewport offset.
    private func synchronizeScrollView() {
        let cellHeight = cellHeightProvider()
        let visibleHeight = scrollView.contentSize.height
        documentView.frame.size.height = SurfaceScrollMath.documentHeight(
            scrollbar: scrollbar,
            cellHeight: cellHeight,
            visibleHeight: visibleHeight
        )

        if !isLiveScrolling {
            let originY = SurfaceScrollMath.scrollOriginY(
                scrollbar: scrollbar,
                cellHeight: cellHeight
            )
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: originY))
            // Mirror the engine's offset in our "what's the current
            // row?" cache so the next live-scroll comparison starts
            // from the right baseline.
            lastSentRow = Int(scrollbar.offset)
        }

        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Position the surface view to fill the currently visible
    /// rectangle. The renderer only draws what's on screen; the
    /// document view "scrolls" by moving the visible rect, and the
    /// surface follows so it stays anchored to the visible area.
    private func synchronizeSurfaceView() {
        let visibleRect = scrollView.contentView.documentVisibleRect
        surfaceView.frame.origin = visibleRect.origin
        surfaceView.frame.size = scrollView.bounds.size
    }

    // MARK: - Observers

    private func installObservers() {
        scrollView.contentView.postsBoundsChangedNotifications = true
        // Clip-view bounds change on every scroll tick (live drag,
        // wheel inertia, programmatic). We use it to keep the
        // surface anchored to the visible rect.
        observers.append(
            NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.synchronizeSurfaceView() }
            }
            )
        observers.append(
            NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isLiveScrolling = true }
            }
            )
        observers.append(
            NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isLiveScrolling = false }
            }
            )
        // The user-driven scroll path. The engine's row is computed
        // from the clip-view origin and dispatched via the
        // `scrollToRow` closure; the `lastSentRow` guard suppresses
        // re-emits while the drag stays inside one row.
        observers.append(
            NotificationCenter.default.addObserver(
            forName: NSScrollView.didLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleLiveScroll() }
            }
            )
    }

    private func handleLiveScroll() {
        let cellHeight = cellHeightProvider()
        guard cellHeight > 0 else { return }
        let visibleRect = scrollView.contentView.documentVisibleRect
        let row = SurfaceScrollMath.row(
            forScrollOriginY: visibleRect.origin.y,
            documentHeight: documentView.frame.height,
            visibleHeight: visibleRect.height,
            cellHeight: cellHeight
        )
        guard row != lastSentRow else { return }
        lastSentRow = row
        scrollToRow(row)
    }

    // MARK: - Legacy-scroller hover flash

    /// When the user's macOS-wide scroller pref is `.legacy`
    /// ("Always show scrollbars"), the scroller is always visible
    /// but the user expects a hover hint to confirm it's
    /// interactive. We mirror Ghostty.app's pattern: install a
    /// tracking area over the scroller's frame and flash the
    /// scrollers when the mouse moves over it. Modern overlay
    /// style auto-fades so the flash is a no-op there.
    override public func mouseMoved(with event: NSEvent) {
        guard NSScroller.preferredScrollerStyle == .legacy else { return }
        scrollView.flashScrollers()
    }

    override public func updateTrackingAreas() {
        for area in trackingAreas { removeTrackingArea(area) }
        super.updateTrackingAreas()
        guard let scroller = scrollView.verticalScroller else { return }
        let scrollerRect = convert(scroller.bounds, from: scroller)
        addTrackingArea(
            NSTrackingArea(
            rect: scrollerRect,
            options: [.mouseMoved, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
            )
    }
}
