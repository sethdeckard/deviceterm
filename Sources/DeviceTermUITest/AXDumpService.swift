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
    /// Several running applications share this bundle identifier, so
    /// choosing an AX root would be arbitrary.
    case ambiguousTarget(bundleID: String, pids: [pid_t])
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
        (AXAttribute.focused, "focused"),
        // Carried for the window, which answers it whenever a represented file
        // is set; that is the titlebar proxy icon's directory. Like `focused`,
        // most elements do not answer it and are simply omitted.
        (AXAttribute.document, "document")
    ]

    /// Role of a top-level item in an application's menu bar.
    private static let menuBarItemRole = "AXMenuBarItem"

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

        let pids = TargetOwners.live(bundleID: bundleID)
        guard let pid = pids.first else {
            throw AXDumpError.appNotRunning(bundleID: bundleID)
        }
        // Multiple matches are unordered. Refuse rather than return a
        // plausible AX tree from the wrong process.
        guard pids.count == 1 else {
            throw AXDumpError.ambiguousTarget(bundleID: bundleID, pids: pids)
        }

        let root = AXUIElementCreateApplication(pid)
        // A trusted process can always create the element; failing to read
        // even a role means the target isn't answering.
        guard AXElementReader.copyAttribute(root, AXAttribute.role) != nil else {
            throw AXDumpError.unreadableRoot(bundleID: bundleID)
        }
        return (root, pid)
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
            children: AXElementReader.children(of:),
            shouldDescend: shouldDescend(into:siblingIndex:)
        )
        var tree = result.root
        tree["pid"] = Int(pid)
        return (tree, result.truncated)
    }

    // MARK: - Traversal policy

    /// Whether the walk should descend into `element`, which sits at
    /// `siblingIndex` among its parent's children.
    ///
    /// macOS owns and populates the leading Apple menu, so its
    /// descendants belong to the system rather than to whichever
    /// application was asked for. The rest of the bar is the target's own
    /// and is walked normally. Position is the ownership signal because
    /// titles are localized, so matching those would quietly stop working
    /// on a non-English system.
    private static func shouldDescend(into element: AXUIElement, siblingIndex: Int) -> Bool {
        guard siblingIndex == 0 else { return true }
        return AXElementReader.string(element, AXAttribute.role) != menuBarItemRole
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
