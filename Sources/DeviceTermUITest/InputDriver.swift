// SPDX-License-Identifier: GPL-3.0-or-later
//
// InputDriver: post the GUI-only gestures that have no CLI equivalent.
//
// Scope discipline: everything deviceterm's CLI can already do goes through
// the CLI. This exists for what it cannot reach: menu key equivalents,
// clicking chrome, and dismissing an app-modal `NSAlert`, which blocks
// deviceterm's own main run loop and therefore cannot be dismissed from
// inside deviceterm at all. Only an out-of-process driver can. The tab,
// pane, and window close prompts are window-modal sheets and do not
// block; plenty of other alerts still do, the quit-with-sims prompt and
// cold-start orphan recovery among them.
//
// Safety: events are delivered with `postToPid`, never to the global HID
// tap. A `cmd+q` posted globally would quit whatever happens to be
// frontmost, plausibly the user's terminal. Even when the target is
// activated first, the event is still addressed to a pid, so a failed
// activation cannot leak a keystroke into another app.
//
// Activation is nonetheless required for key equivalents. A menu command
// runs against the key window, and a backgrounded app has none: posting
// cmd+t to a background deviceterm opens a *window* rather than adding a
// tab, because "New Tab" finds no window to add to. Observed, not assumed.
// `pressElement` needs no activation, since an AX action is semantic
// rather than focus-dependent, so it stays the non-invasive option.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum InputDriver {
    /// How long to wait for an activated app to actually become frontmost.
    private static let activationTimeout: TimeInterval = 1.5

    /// How long to leave the target frontmost after posting, so it processes
    /// the gesture against its key window before focus is handed back.
    private static let settleAfterPost: useconds_t = 120_000

    /// Run `body` with `pid` frontmost, then return focus to whoever had it.
    ///
    /// Key equivalents resolve against the key window, and a background app
    /// has none, so a drive must briefly activate its target. That briefly
    /// steals the user's keyboard focus, so it is borrowed, not kept: the
    /// previously-frontmost app is reactivated once the gesture has settled.
    /// A drive still interrupts, so a playbook should run when the machine is
    /// idle; this just keeps a stray drive from swallowing the next thing the
    /// user types.
    ///
    /// Activation is best-effort. Even if it fails the gesture stays safe,
    /// because the event is addressed to `pid`, never the global tap.
    static func withActivation(pid: pid_t, _ body: () throws -> Void) rethrows {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isActive else {
            try body()
            return
        }
        let previous = NSWorkspace.shared.frontmostApplication
        app.activate()
        waitUntilActive(app)

        try body()

        // Let the target handle the event while it is still frontmost, then
        // give focus back if it wasn't already the foreground app.
        usleep(settleAfterPost)
        if let previous, previous.processIdentifier != pid, !previous.isTerminated {
            previous.activate()
        }
    }

    private static func waitUntilActive(_ app: NSRunningApplication) {
        let deadline = Date().addingTimeInterval(activationTimeout)
        while Date() < deadline, !app.isActive {
            usleep(20_000)
        }
    }

    /// Post a key-down/key-up pair to `pid`, activating it first so the
    /// keystroke resolves against a key window.
    static func postKey(_ shortcut: KeyShortcut, toPID pid: pid_t) throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw InputDriverError.eventSourceUnavailable
        }
        guard
            let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: shortcut.keyCode,
                keyDown: true
            ),
            let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: shortcut.keyCode,
                keyDown: false
            )
        else {
            throw InputDriverError.eventCreationFailed
        }
        keyDown.flags = shortcut.flags
        keyUp.flags = shortcut.flags

        withActivation(pid: pid) {
            keyDown.postToPid(pid)
            // AppKit dispatches the key equivalent on key-down; the up event
            // keeps the target's modifier bookkeeping honest.
            usleep(15_000)
            keyUp.postToPid(pid)
        }
    }

    /// Press the first element whose title, description, or identifier
    /// matches `needle` exactly.
    ///
    /// Exact match on purpose: a substring match that silently pressed the
    /// wrong button ("Cancel" inside "Cancel All") is far worse than a
    /// failure telling the caller to be specific.
    static func pressElement(
        matching needle: String,
        bundleID: String,
        limits: AXTreeLimits = .default
    ) throws {
        let (root, pid) = try AXDumpService.applicationElement(bundleID: bundleID)
        guard let element = findElement(from: root, needle: needle, limits: limits) else {
            throw InputDriverError.noMatchingElement(needle: needle)
        }
        guard AXElementReader.supportsPress(element) else {
            throw InputDriverError.elementDoesNotSupportPress(needle: needle)
        }
        // An AX action triggers the element's handler, but that handler can
        // itself be key-window-dependent: pressing "New Tab" on a background
        // deviceterm opens a window, not a tab. Activating first makes every
        // drive verb behave the way its name implies. Observed, not assumed.
        var pressed = false
        withActivation(pid: pid) {
            pressed = AXElementReader.press(element)
        }
        guard pressed else {
            throw InputDriverError.pressFailed(needle: needle)
        }
    }

    /// Click a point given in the target window's normalized coordinates,
    /// where (0,0) is the window's top-left and (1,1) its bottom-right.
    ///
    /// Normalized to the *window*, not the screen: a playbook should not
    /// have to know the display geometry, and a window that moves must not
    /// invalidate a scenario.
    @discardableResult
    static func click(
        normalizedX x: Double,
        normalizedY y: Double,
        bundleID: String
    ) throws -> CGPoint {
        guard (0...1).contains(x), (0...1).contains(y) else {
            throw InputDriverError.pointOutOfRange(x: x, y: y)
        }
        let (root, pid) = try AXDumpService.applicationElement(bundleID: bundleID)
        guard let frame = focusedWindowFrame(of: root) else {
            throw InputDriverError.noWindow(bundleID: bundleID)
        }

        let point = CGPoint(
            x: frame.origin.x + frame.size.width * x,
            y: frame.origin.y + frame.size.height * y
        )
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw InputDriverError.eventSourceUnavailable
        }
        guard
            let mouseDown = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseDown,
                mouseCursorPosition: point,
                mouseButton: .left
            ),
            let mouseUp = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseUp,
                mouseCursorPosition: point,
                mouseButton: .left
            )
        else {
            throw InputDriverError.eventCreationFailed
        }
        // A click on a background window would otherwise only raise it.
        withActivation(pid: pid) {
            mouseDown.postToPid(pid)
            usleep(15_000)
            mouseUp.postToPid(pid)
        }
        return point
    }

    // MARK: - Lookup

    /// The window a click should be measured against: the focused one, else
    /// the main one, else the first.
    private static func focusedWindowFrame(of application: AXUIElement) -> CGRect? {
        let focused = AXElementReader.element(application, AXAttribute.focusedWindow)
        let main = AXElementReader.element(application, AXAttribute.mainWindow)
        let first = AXElementReader.children(of: application).first { element in
            AXElementReader.string(element, AXAttribute.role) == "AXWindow"
        }
        guard let window = focused ?? main ?? first else { return nil }
        return AXElementReader.frame(of: window)
    }

    /// Depth-first search bounded by the same ceilings the dump uses, so a
    /// pathological tree cannot spin here either.
    private static func findElement(
        from root: AXUIElement,
        needle: String,
        limits: AXTreeLimits
    ) -> AXUIElement? {
        var budget = limits.maxNodes

        func visit(_ element: AXUIElement, depth: Int) -> AXUIElement? {
            if budget <= 0 { return nil }
            budget -= 1

            if matches(element, needle: needle) { return element }
            guard depth < limits.maxDepth else { return nil }

            for child in AXElementReader.children(of: element) {
                if let hit = visit(child, depth: depth + 1) { return hit }
            }
            return nil
        }
        return visit(root, depth: 0)
    }

    private static func matches(_ element: AXUIElement, needle: String) -> Bool {
        let candidates = [
            AXElementReader.string(element, AXAttribute.title),
            AXElementReader.string(element, AXAttribute.description),
            AXElementReader.string(element, AXAttribute.identifier)
        ]
        return candidates.contains { $0 == needle }
    }
}
