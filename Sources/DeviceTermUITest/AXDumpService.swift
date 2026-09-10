// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ApplicationServices
import Foundation

/// Read another app's AppKit accessibility tree.
///
/// This is the structured counterpart to a screenshot: instead of asking a
/// model to look at pixels, an agent can assert that the tab strip holds
/// three AXCheckBoxes, or that an AXSheet is present. AX provides
/// structured roles, labels, values, frames, and hierarchy for assertions;
/// screenshots cover rendered properties the tree omits.
///
/// Requires the Accessibility grant, which belongs to this resident harness
/// (see TCCStatus). Reading a foreign process's tree is IPC, so every call
/// can block, hence the global messaging timeout below.
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

    /// The application-level AX element for `bundleID`, with the process-wide
    /// messaging timeout already applied.
    ///
    /// Shared with the input driver: both need "resolve a bundle id to a
    /// live, bounded AX root, or say precisely why not."
    static func applicationElement(bundleID: String) throws -> (element: AXUIElement, pid: pid_t) {
        let elements = try applicationElements(bundleID: bundleID)
        guard let only = elements.first else {
            throw AXDumpError.appNotRunning(bundleID: bundleID)
        }
        // Multiple matches are unordered. Refuse rather than return a
        // plausible AX tree from the wrong process.
        guard elements.count == 1 else {
            throw AXDumpError.ambiguousTarget(bundleID: bundleID, pids: elements.map(\.pid))
        }
        // A trusted process can always create the element; failing to read
        // even a role means the target isn't answering.
        guard AXElementReader.copyAttribute(only.element, AXAttribute.role) != nil else {
            throw AXDumpError.unreadableRoot(bundleID: bundleID)
        }
        return only
    }

    /// AX roots for *every* live process under `bundleID`, sorted by pid,
    /// empty when none is running.
    ///
    /// `applicationElement` refuses more than one, which is right when the
    /// answer is a tree that has to come from a particular process. A caller
    /// asking a question every instance can answer at once ("is any of them
    /// showing a menu-bar item?") needs them all, so that it can distinguish
    /// a genuine ambiguity from a state they agree on.
    static func applicationElements(
        bundleID: String
    ) throws -> [(element: AXUIElement, pid: pid_t)] {
        guard TCCStatus.hasAccessibility else { throw AXDumpError.notTrusted }

        // Bound every AX read in this process, including the child elements a
        // walk creates on the fly. Must precede element creation so they
        // inherit the global default.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeout)

        return TargetOwners.live(bundleID: bundleID).map {
            (AXUIElementCreateApplication($0), $0)
        }
    }

    static func dump(
        bundleID: String,
        limits: AXTreeLimits = .default
    ) throws -> AXTreeResult {
        let (root, pid) = try applicationElement(bundleID: bundleID)

        var result = AXTreeBuilder.build(
            root: root,
            limits: limits,
            attributes: attributes(of:),
            children: AXElementReader.childrenIfReadable(of:),
            shouldDescend: shouldDescend(node:siblingIndex:)
        )
        result.tree["pid"] = Int(pid)
        return result
    }

    // MARK: - Traversal policy

    /// Whether the walk should descend into the node just read, which sits
    /// at `siblingIndex` among its parent's children. `AXTraversalPolicy`
    /// holds the rule and the reasoning, shared with the input driver.
    ///
    /// Decided from the attributes the walk already read rather than a fresh
    /// read of its own: a second read can disagree with the first, and a
    /// policy deciding on its own would prune, or fail to prune, a subtree
    /// the emitted node cannot account for.
    private static func shouldDescend(node: [String: Any], siblingIndex: Int) -> Bool {
        AXTraversalPolicy.shouldEnter(
            role: node["role"] as? String,
            siblingIndex: siblingIndex
        )
    }

    // MARK: - Element reading

    /// Serialize one element, reading each attribute exactly once.
    ///
    /// An absent attribute is omitted; a failed read records that attribute's
    /// name on the node. Most elements publish only a handful of these, so
    /// conflating the two would either mark
    /// every node or hide the failures: a tab whose `identifier` timed out
    /// would serialize as a node carrying none, and a caller counting pills
    /// would score it zero and call that an observation.
    ///
    /// The recorded name is the accessibility attribute (`AXTitle`), not the
    /// JSON key this dump chose for it (`title`), because a reader deciding
    /// whether the failure touches its assertion is reasoning about the AX
    /// attribute.
    private static func attributes(of element: AXUIElement) -> [String: Any] {
        var node: [String: Any] = [:]
        for pair in scalarAttributes {
            switch AXElementReader.read(element, pair.ax) {
            case let .value(raw):
                if let value = AXElementReader.jsonSafe(raw) { node[pair.json] = value }

            case .absent:
                continue

            case .failed:
                AXTreeBuilder.mark(&node, unreadable: pair.ax)
            }
        }
        switch AXElementReader.frameRead(of: element) {
        case let .value(frame):
            node["frame"] = [
                "x": frame.origin.x,
                "y": frame.origin.y,
                "width": frame.size.width,
                "height": frame.size.height
            ]

        case .absent:
            break

        case let .failed(attributes):
            for attribute in attributes {
                AXTreeBuilder.mark(&node, unreadable: attribute)
            }
        }
        return node
    }
}
