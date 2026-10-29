// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The window, tab, and pane layout written at quit and read back at the next
/// launch, so relaunching reopens what was open.
///
/// Layout only, never authority. The file sits where any same-uid process can
/// rewrite it, so nothing in it may grant anything: no session id, capability,
/// role, command, or simulator ownership is recorded. Every restored terminal
/// gets a fresh `session.create`, a restored sim pane borrows rather than
/// claims its simulator, and automation tabs are left to the
/// `automation-programs` file that opens them.
///
/// `Node` uses explicit coding to keep its enum representation stable across
/// in-memory changes. `version` gates the whole file: one written by a
/// different version is ignored, and the launch opens a single new window.
struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    /// One saved window: its frame, its tabs in strip order, and which was
    /// selected.
    struct Window: Codable, Equatable, Sendable {
        /// The window's frame in screen coordinates, nil when it wasn't known.
        var frame: Frame?
        var tabs: [Tab]
        /// Index into `tabs`.
        var selectedTab: Int?
    }

    /// A window frame in AppKit screen coordinates (origin bottom-left).
    struct Frame: Codable, Equatable, Sendable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

        init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        init(_ rect: CGRect) {
            self.init(
                x: rect.origin.x,
                y: rect.origin.y,
                width: rect.size.width,
                height: rect.size.height
            )
        }
    }

    /// One saved tab.
    struct Tab: Codable, Equatable, Sendable {
        /// The name the user gave the tab, nil for the automatic title.
        var title: String?
        var isPinned: Bool
        var layout: Node
        /// The pane the tab last held focus in, as an index into the
        /// layout's leaves in display order.
        var focusedLeaf: Int?
    }

    /// A terminal leaf: where its shell was, the name `pane rename` gave
    /// it, and the id of its saved scrollback when `restore-scrollback` saved
    /// some (see `ScrollbackStore`).
    struct Terminal: Codable, Equatable, Sendable {
        var cwd: String?
        var name: String?
        var scrollback: String?
    }

    /// A simulator or physical-device leaf. `id` is the simulator's UDID or
    /// the device's CoreDevice id, by the leaf's case.
    struct Device: Codable, Equatable, Sendable {
        var id: String
        /// The label the pane showed, kept so the placeholder reads right
        /// while the attach runs.
        var displayName: String?
        /// The name `pane rename` gave the pane.
        var name: String?
        /// Coarse device family (wire string), which sizes the placeholder.
        var family: String?
        /// `SimSizePreset` raw value. An unrecognized value restores none.
        var sizePreset: String?
    }

    /// The pane tree: a leaf, or a split of two or more children with one
    /// divider proportion per child.
    indirect enum Node: Codable, Equatable, Sendable {
        case terminal(Terminal)
        case sim(Device)
        case device(Device)
        /// `ratios` holds each child's share of the split, nil when none was
        /// recorded, in which case the panes size themselves as for a new
        /// split.
        case split(axis: SplitAxis, children: [Node], ratios: [Double]?)

        private enum CodingKeys: String, CodingKey {
            case type, terminal, device, axis, children, ratios
        }

        private enum Kind: String, Codable {
            case terminal, sim, device, split
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .type) {
            case .terminal:
                self = .terminal(try container.decode(Terminal.self, forKey: .terminal))

            case .sim:
                self = .sim(try container.decode(Device.self, forKey: .device))

            case .device:
                self = .device(try container.decode(Device.self, forKey: .device))

            case .split:
                self = .split(
                    axis: try container.decode(SplitAxis.self, forKey: .axis),
                    children: try container.decode([Node].self, forKey: .children),
                    ratios: try container.decodeIfPresent([Double].self, forKey: .ratios)
                )
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .terminal(terminal):
                try container.encode(Kind.terminal, forKey: .type)
                try container.encode(terminal, forKey: .terminal)

            case let .sim(device):
                try container.encode(Kind.sim, forKey: .type)
                try container.encode(device, forKey: .device)

            case let .device(device):
                try container.encode(Kind.device, forKey: .type)
                try container.encode(device, forKey: .device)

            case let .split(axis, children, ratios):
                try container.encode(Kind.split, forKey: .type)
                try container.encode(axis, forKey: .axis)
                try container.encode(children, forKey: .children)
                try container.encodeIfPresent(ratios, forKey: .ratios)
            }
        }
    }

    /// The format this build writes and the only one it reads.
    static let currentVersion = 1

    var version: Int
    var windows: [Window]
    /// Index into `windows`.
    var selectedWindow: Int?

    init(
        windows: [Window],
        selectedWindow: Int?,
        version: Int = Self.currentVersion
    ) {
        self.version = version
        self.windows = windows
        self.selectedWindow = selectedWindow
    }
}
