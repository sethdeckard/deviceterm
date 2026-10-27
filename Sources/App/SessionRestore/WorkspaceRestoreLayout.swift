// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import DaemonProtocol
import Foundation

/// The pure half of restoring one saved tab: checking a layout read from disk,
/// and mapping it onto the panes the Router creates for it.
///
/// A saved layout is untrusted input, so `sanitized` repairs what the live
/// tree's invariants forbid rather than trusting the file to respect them:
/// a sim named by something other than a UUID goes, a sim or device named
/// twice keeps its first leaf, a split left with one child collapses into it,
/// an empty one goes, and proportions that don't fit their split are dropped
/// so the panes size as a new split would.
enum WorkspaceRestoreLayout {
    /// A restored tab's tree, plus what its layout controller is seeded with.
    struct Built: Equatable {
        let tree: PaneNode
        /// Divider proportions by split path.
        let ratios: [[Int]: [CGFloat]]
        /// Each sim leaf's path, keyed by its target. Seeded as the panes'
        /// last-mounted paths, so a sim that comes back where it was saved
        /// reads as a re-attach and keeps the saved proportions instead of
        /// being refitted as a new pane.
        let simFitPaths: [PaneTarget: [Int]]
    }

    /// A layout with some of its leaves removed, and the input position of
    /// each leaf that stayed.
    struct Filtered: Equatable {
        /// Nil when no leaf stayed.
        let node: WorkspaceSnapshot.Node?
        /// The display-order index, in the input, of each kept leaf, in
        /// order. Maps a saved leaf index (`Tab.focusedLeaf`) onto the result.
        let kept: [Int]
    }

    /// `node` with every leaf validated and every split repaired. A tab also
    /// needs a terminal leaf, which `hasTerminal` reports.
    static func sanitized(_ node: WorkspaceSnapshot.Node) -> Filtered {
        var seen: Set<PaneTarget> = []
        let canonical = canonicalized(node)
        return filtered(canonical) { _, leaf in
            switch leaf {
            case .terminal:
                return true

            case let .sim(device):
                // A simulator UDID is a UUID. Anything else can't name one.
                guard UUID(uuidString: device.id) != nil else { return false }
                return seen.insert(simTarget(device)).inserted

            case let .device(device):
                guard !device.id.isEmpty else { return false }
                return seen.insert(.device(deviceId: device.id)).inserted

            case .split:
                return false
            }
        }
    }

    /// `node` without the leaves at `indices` (display order), with splits
    /// repaired as `sanitized` repairs them. For a terminal whose session
    /// couldn't be created.
    static func removing(leaves indices: Set<Int>, from node: WorkspaceSnapshot.Node) -> Filtered {
        filtered(node) { index, _ in !indices.contains(index) }
    }

    /// The directory a restored terminal starts in: `saved` when it is an
    /// absolute path to an existing directory, else the home directory. The
    /// path comes from a file anything running as the user can edit, so it
    /// is checked rather than handed to the shell as is.
    static func restorableDirectory(
        _ saved: String?,
        home: String = NSHomeDirectory(),
        isDirectory: (String) -> Bool = { path in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &directory)
                && directory.boolValue
        }
    ) -> String {
        guard let saved, (saved as NSString).isAbsolutePath, isDirectory(saved) else { return home }
        return saved
    }

    /// Whether `node` has a terminal leaf. Every tab keeps one terminal at
    /// least, so a layout without one can't become a tab.
    static func hasTerminal(_ node: WorkspaceSnapshot.Node) -> Bool {
        leaves(node).contains {
            if case .terminal = $0 { return true }
            return false
        }
    }

    /// The leaves of `node` in display order.
    static func leaves(_ node: WorkspaceSnapshot.Node) -> [WorkspaceSnapshot.Node] {
        switch node {
        case .terminal, .sim, .device:
            return [node]

        case let .split(_, children, _):
            return children.flatMap(leaves)
        }
    }

    /// Build the live tree for a sanitized `node`, taking `slots` for its
    /// leaves in display order. `slots` must hold one entry per leaf.
    static func build(_ node: WorkspaceSnapshot.Node, slots: [PaneSlot]) -> Built {
        precondition(slots.count == leaves(node).count, "one slot per restored leaf")
        var next = 0
        var ratios: [[Int]: [CGFloat]] = [:]
        var simFitPaths: [PaneTarget: [Int]] = [:]
        let tree = build(
            node,
            path: [],
            slots: slots,
            next: &next,
            ratios: &ratios,
            simFitPaths: &simFitPaths
        )
        return Built(tree: tree, ratios: ratios, simFitPaths: simFitPaths)
    }

    /// The sim target a saved sim leaf names. UDIDs are canonicalized the way
    /// the daemon stores them, so the restored pane and its seeded fit path
    /// agree on one spelling.
    static func simTarget(_ device: WorkspaceSnapshot.Device) -> PaneTarget {
        .sim(udid: PublicIdentifier.canonicalized(device.id))
    }

    /// Sim UDIDs in the spelling the daemon stores.
    private static func canonicalized(_ node: WorkspaceSnapshot.Node) -> WorkspaceSnapshot.Node {
        switch node {
        case .terminal, .device:
            return node

        case let .sim(device):
            var canonical = device
            canonical.id = PublicIdentifier.canonicalized(device.id)
            return .sim(canonical)

        case let .split(axis, children, ratios):
            return .split(axis: axis, children: children.map(canonicalized), ratios: ratios)
        }
    }

    /// Keep the leaves `keep` accepts, given each leaf's display-order index
    /// and the leaf. A split left with one child collapses into it, an empty
    /// one goes, and a split that lost a child, or whose proportions don't
    /// fit it, drops its proportions.
    private static func filtered(
        _ node: WorkspaceSnapshot.Node,
        keep: (Int, WorkspaceSnapshot.Node) -> Bool
    ) -> Filtered {
        var next = 0
        var kept: [Int] = []
        let result = filtered(node, next: &next, kept: &kept, keep: keep)
        return Filtered(node: result, kept: kept)
    }

    private static func filtered(
        _ node: WorkspaceSnapshot.Node,
        next: inout Int,
        kept: inout [Int],
        keep: (Int, WorkspaceSnapshot.Node) -> Bool
    ) -> WorkspaceSnapshot.Node? {
        switch node {
        case .terminal, .sim, .device:
            let index = next
            next += 1
            guard keep(index, node) else { return nil }
            kept.append(index)
            return node

        case let .split(axis, children, ratios):
            var keptChildren: [WorkspaceSnapshot.Node] = []
            for child in children {
                if let child = filtered(child, next: &next, kept: &kept, keep: keep) {
                    keptChildren.append(child)
                }
            }
            if keptChildren.isEmpty { return nil }
            if keptChildren.count == 1 { return keptChildren[0] }
            let usable = keptChildren.count == children.count
                ? ratios.flatMap { validRatios($0, count: children.count) ? $0 : nil }
                : nil
            return .split(axis: axis, children: keptChildren, ratios: usable)
        }
    }

    private static func validRatios(_ ratios: [Double], count: Int) -> Bool {
        ratios.count == count && ratios.allSatisfy { $0.isFinite && $0 > 0 }
    }

    private static func build(
        _ node: WorkspaceSnapshot.Node,
        path: [Int],
        slots: [PaneSlot],
        next: inout Int,
        ratios: inout [[Int]: [CGFloat]],
        simFitPaths: inout [PaneTarget: [Int]]
    ) -> PaneNode {
        switch node {
        case .terminal, .device:
            defer { next += 1 }
            return .leaf(slots[next])

        case let .sim(device):
            simFitPaths[simTarget(device)] = path
            defer { next += 1 }
            return .leaf(slots[next])

        case let .split(axis, children, saved):
            let built = children.enumerated().map { index, child in
                build(
                    child,
                    path: path + [index],
                    slots: slots,
                    next: &next,
                    ratios: &ratios,
                    simFitPaths: &simFitPaths
                )
            }
            let shares: [CGFloat]
            if let saved {
                let total = saved.reduce(0, +)
                shares = saved.map { CGFloat($0 / total) }
                ratios[path] = shares
            } else {
                shares = Array(repeating: 1 / CGFloat(children.count), count: children.count)
            }
            return .split(axis: axis, children: built, extents: shares)
        }
    }
}
