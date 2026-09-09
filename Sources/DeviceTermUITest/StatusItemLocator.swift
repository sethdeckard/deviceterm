// SPDX-License-Identifier: GPL-3.0-or-later

import ApplicationServices
import CoreGraphics
import Foundation

/// Where the daemon's menu-bar status item sits on screen.
///
/// The badge cannot be found by asking who owns its window. macOS hosts
/// every menu-bar extra in Control Center's process, so the window server
/// attributes the badge to Control Center while the daemon owns no
/// on-screen window at all. No `owningApplication` accessor reaches it,
/// by bundle id or by pid.
///
/// Accessibility is the one interface that still names the item as the
/// daemon's, so it supplies the frame and the capture path matches a
/// window against it. That makes the Accessibility grant a requirement of
/// the status-item capture, not just of `ax dump`.
///
/// Every read here fails closed. With a daemon running, absence is reported
/// only after its tree was read successfully and held no item; an unreadable
/// tree throws instead. No running daemon is absence too, reached without
/// reading a tree at all. Folding a failed read in with those would report
/// "no badge" for a timed-out one, which is indistinguishable from the
/// hidden-at-zero-sims state.
enum StatusItemLocator {
    /// Role of the tree's own root. Seeing it again below the root is the
    /// known self-nesting degenerate read.
    private static let applicationRole = "AXApplication"

    private static let menuBarRole = "AXMenuBar"

    /// Role of a top-level item within that bar. The daemon publishes
    /// exactly one: the badge.
    private static let menuBarItemRole = "AXMenuBarItem"

    /// The daemon's published status-item frame in top-left-origin screen
    /// points, or nil when no running daemon publishes an item. Whether an
    /// on-screen window hosts that frame is decided downstream, by the
    /// capture path.
    ///
    /// Nil covers two states: no daemon is running (for example, after idle
    /// exit), or the daemons that are running publish no menu-bar item,
    /// which is what zero owned booted sims looks like. All other states
    /// throw: an unreadable tree, more than one daemon when a badge is
    /// showing, or an item with no readable frame.
    static func badgeFrame(bundleID: String) throws -> CGRect? {
        let daemons = try AXDumpService.applicationElements(bundleID: bundleID)
        var items: [AXUIElement] = []
        for daemon in daemons {
            items += try menuBarItems(of: daemon.element, bundleID: bundleID)
        }

        // Nobody is showing a badge, so absence is the answer whichever
        // instance the caller meant, and asking every instance is what earns
        // the right to say so. Refusing on instance count alone would turn
        // the ordinary zero-sims state into an error whenever a second
        // daemon is alive, which the GUI smoke routinely leaves behind.
        guard let item = items.first else { return nil }

        // Once a badge *is* showing, ambiguity is about which instance the
        // caller meant, so it counts every live daemon rather than only the
        // ones publishing an item. A hidden second daemon still makes the
        // target ambiguous: one checkout showing a badge beside another's
        // idle helper is the ordinary way this happens, and capturing the
        // visible one would answer for a process the caller may not have
        // meant.
        guard daemons.count == 1 else {
            throw CaptureError.ambiguousTarget(bundleID: bundleID, pids: daemons.map(\.pid))
        }
        // One daemon vends one status item, so a second means the tree does
        // not match what this selector assumes. Refuse rather than capture
        // whichever came back first.
        guard items.count == 1 else {
            throw CaptureError.ambiguousStatusItem(bundleID: bundleID, count: items.count)
        }
        guard let frame = AXElementReader.frame(of: item) else {
            throw CaptureError.statusItemUnreadable(bundleID: bundleID)
        }
        return frame
    }

    private static func menuBarItems(
        of application: AXUIElement,
        bundleID: String
    ) throws -> [AXUIElement] {
        var items: [AXUIElement] = []
        for child in try children(of: application, bundleID: bundleID) {
            let childRole = try role(of: child, bundleID: bundleID)
            // An application element never legitimately contains another, so
            // a self-nesting tree is degenerate. Skipping it as an
            // uninteresting child would find no menu bar below it and report
            // the badge hidden.
            guard childRole != applicationRole else {
                throw CaptureError.statusItemTreeDegenerate(bundleID: bundleID)
            }
            guard childRole == menuBarRole else { continue }
            for candidate in try children(of: child, bundleID: bundleID) {
                guard try role(of: candidate, bundleID: bundleID) == menuBarItemRole else {
                    continue
                }
                items.append(candidate)
            }
        }
        return items
    }

    private static func children(
        of element: AXUIElement,
        bundleID: String
    ) throws -> [AXUIElement] {
        guard let children = AXElementReader.childrenIfReadable(of: element) else {
            throw CaptureError.statusItemUnreadable(bundleID: bundleID)
        }
        return children
    }

    /// Every accessibility element answers `AXRole`, so a read that comes
    /// back empty is a failed read rather than a role-less element.
    private static func role(of element: AXUIElement, bundleID: String) throws -> String {
        guard let role = AXElementReader.string(element, AXAttribute.role) else {
            throw CaptureError.statusItemUnreadable(bundleID: bundleID)
        }
        return role
    }
}
