// SPDX-License-Identifier: GPL-3.0-or-later
//
// AXDumpService: read another app's AppKit accessibility tree.
//
// This is the structured counterpart to a screenshot: instead of asking a
// model to look at pixels, an agent can assert that the tab strip holds
// three AXCheckBoxes, or that an AXSheet is present. Pixels still catch
// what no schema encodes (layout, color, overlap); AX catches everything
// else, deterministically.
//
// Requires the Accessibility grant, which belongs to this resident harness
// (see TCCStatus). Reading a foreign process's tree is IPC, so every call
// can block, hence the global messaging timeout below.

import AppKit
import ApplicationServices
import Foundation

enum AXDumpError: Error, Equatable {
    case appNotRunning(bundleID: String)
    /// The harness lacks the Accessibility grant. Distinct from an AX error
    /// because the fix is a checkbox, not a code change.
    case notTrusted
    case unreadableRoot(bundleID: String)
}

enum AXDumpService {
    /// How long a single AX message may block before failing. deviceterm can
    /// sit inside a modal run loop; without this a read could hang the worker
    /// until its socket deadline fires.
    ///
    /// Applied to the *system-wide* element, which is the only way to bound
    /// every read. Per `AXUIElement.h`: "Pass the system-wide accessibility
    /// object if you want to set the timeout globally for this process.
    /// Setting the timeout on another accessibility object sets it only for
    /// that object." The children returned by `AXChildren` are fresh
    /// elements, so a per-application timeout would leave every read below
    /// the root unbounded.
    static let messagingTimeout: Float = 2.0

    /// Attributes worth carrying into the dump, and their JSON keys.
    private static let scalarAttributes: [(ax: String, json: String)] = [
        (AXAttribute.role, "role"),
        (AXAttribute.subrole, "subrole"),
        (AXAttribute.title, "title"),
        (AXAttribute.value, "value"),
        (AXAttribute.description, "description"),
        (AXAttribute.identifier, "identifier"),
        (AXAttribute.help, "help"),
        // Carried for the pane wrappers, which publish it so a focus
        // shortcut can be asserted from outside the app. Most elements
        // do not answer it and are simply omitted.
        (AXAttribute.focused, "focused")
    ]

    /// The application-level AX element for `bundleID`, with the process-wide
    /// messaging timeout already applied.
    ///
    /// Shared with the input driver: both need "resolve a bundle id to a
    /// live, bounded AX root, or say precisely why not."
    static func applicationElement(bundleID: String) throws -> (element: AXUIElement, pid: pid_t) {
        guard TCCStatus.hasAccessibility else { throw AXDumpError.notTrusted }

        // Bound every AX read in this process, including the child elements a
        // walk creates on the fly. Must precede element creation so they
        // inherit the global default.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeout)

        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard let app = running.first else {
            throw AXDumpError.appNotRunning(bundleID: bundleID)
        }

        let root = AXUIElementCreateApplication(app.processIdentifier)
        // A trusted process can always create the element; failing to read
        // even a role means the target isn't answering.
        guard AXElementReader.copyAttribute(root, AXAttribute.role) != nil else {
            throw AXDumpError.unreadableRoot(bundleID: bundleID)
        }
        return (root, app.processIdentifier)
    }

    static func dump(
        bundleID: String,
        limits: AXTreeLimits = .default
    ) throws -> (tree: [String: Any], truncated: Bool) {
        let (root, pid) = try applicationElement(bundleID: bundleID)

        let result = AXTreeBuilder.build(
            root: root,
            limits: limits,
            attributes: attributes(of:),
            children: AXElementReader.children(of:)
        )
        var tree = result.root
        tree["pid"] = Int(pid)
        return (tree, result.truncated)
    }

    // MARK: - Element reading

    private static func attributes(of element: AXUIElement) -> [String: Any] {
        var node: [String: Any] = [:]
        for pair in scalarAttributes {
            guard let raw = AXElementReader.copyAttribute(element, pair.ax) else { continue }
            if let value = AXElementReader.jsonSafe(raw) { node[pair.json] = value }
        }
        if let frame = AXElementReader.frame(of: element) {
            node["frame"] = [
                "x": frame.origin.x,
                "y": frame.origin.y,
                "width": frame.size.width,
                "height": frame.size.height
            ]
        }
        return node
    }
}
