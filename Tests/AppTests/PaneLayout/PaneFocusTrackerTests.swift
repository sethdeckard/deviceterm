// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import AppKit
import Testing

/// Pin the shared focus resolver both pane wrappers sit on.
///
/// The tracker exists because a pane root cannot be asked whether it
/// holds focus: the normal live-pane first responder is an embedded
/// descendant. It polls `NSWindow.didUpdateNotification` and reports
/// resolved changes. It also re-resolves when the tracked view changes
/// windows, covering removal without a `resignFirstResponder` callback,
/// which is what a tab switch does to every pane in the outgoing tab.
@MainActor
struct PaneFocusTrackerTests {
    /// A tracked view with a focus-accepting descendant, mounted in a
    /// window under a removable host.
    private struct Mount {
        let tracker: PaneFocusTracker
        let view: NSView
        let target: NSView
        let window: NSWindow
        let host: NSView
    }

    private func makeMount() -> Mount {
        let tracker = PaneFocusTracker()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let target = FocusAcceptingView(frame: view.bounds)
        view.addSubview(target)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        window.contentView = host
        host.addSubview(view)
        tracker.viewDidMoveToWindow(view)
        return Mount(
            tracker: tracker,
            view: view,
            target: target,
            window: window,
            host: host
        )
    }

    @Test
    func resolvesFocusArrivingInsideTheTrackedView() async throws {
        let mount = makeMount()
        var reported: [Bool] = []
        mount.tracker.onFocusChange = { reported.append($0) }
        #expect(mount.tracker.isFocused == false)

        _ = mount.window.makeFirstResponder(mount.target)
        mount.window.update()
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(mount.tracker.isFocused)
        #expect(reported == [true])
    }

    @Test
    func clearsSynchronouslyWhenTheViewLeavesTheWindow() async throws {
        // Detaching the tracked view must clear focus synchronously.
        // AppKit drops the window's first responder when a
        // first-responder view is pulled out of the hierarchy and
        // delivers no `resignFirstResponder`, so re-resolving on the
        // window change is the only thing that can notice.
        let mount = makeMount()
        _ = mount.window.makeFirstResponder(mount.target)
        mount.window.update()
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(mount.tracker.isFocused)

        var reported: [Bool] = []
        mount.tracker.onFocusChange = { reported.append($0) }
        mount.view.removeFromSuperview()
        mount.tracker.viewDidMoveToWindow(mount.view)
        #expect(mount.tracker.isFocused == false)
        #expect(reported == [false])
    }

    @Test
    func reportsOnlyResolvedChanges() async throws {
        let mount = makeMount()
        _ = mount.window.makeFirstResponder(mount.target)
        mount.window.update()
        try await Task.sleep(nanoseconds: 30_000_000)

        var reported: [Bool] = []
        mount.tracker.onFocusChange = { reported.append($0) }
        for _ in 0..<5 {
            mount.window.update()
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(reported.isEmpty)
    }

    @Test
    func rearmsAgainstASecondWindow() async throws {
        // The notification is registered per window (`object:`), so a
        // pane dragged into another window would keep watching the old
        // one and go deaf to the window it is actually in.
        let first = makeMount()
        let secondWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        let secondHost = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        secondWindow.contentView = secondHost

        first.view.removeFromSuperview()
        secondHost.addSubview(first.view)
        first.tracker.viewDidMoveToWindow(first.view)

        _ = secondWindow.makeFirstResponder(first.target)
        secondWindow.update()
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(first.tracker.isFocused)
    }
}

/// Stands in for the descendant that really holds first responder in a
/// live pane: libghostty's surface, or the Metal content view.
@MainActor
private final class FocusAcceptingView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
