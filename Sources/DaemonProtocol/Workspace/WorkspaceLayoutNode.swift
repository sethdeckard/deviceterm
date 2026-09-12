// SPDX-License-Identifier: GPL-3.0-or-later

/// Recursive public layout tree returned by `tab show`.
public indirect enum WorkspaceLayoutNode: Codable, Sendable, Equatable {
    case pane(id: String)
    case split(axis: String, extents: [Double], children: [WorkspaceLayoutNode])

    private enum CodingKeys: String, CodingKey {
        case type
        case paneId
        case axis
        case extents
        case children
    }

    private enum NodeType: String, Codable {
        case pane
        case split
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(NodeType.self, forKey: .type) {
        case .pane:
            self = try .pane(id: container.decode(String.self, forKey: .paneId))

        case .split:
            self = try .split(
                axis: container.decode(String.self, forKey: .axis),
                extents: container.decode([Double].self, forKey: .extents),
                children: container.decode([WorkspaceLayoutNode].self, forKey: .children)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .pane(id):
            try container.encode(NodeType.pane, forKey: .type)
            try container.encode(id, forKey: .paneId)

        case let .split(axis, extents, children):
            try container.encode(NodeType.split, forKey: .type)
            try container.encode(axis, forKey: .axis)
            try container.encode(extents, forKey: .extents)
            try container.encode(children, forKey: .children)
        }
    }
}
