// SPDX-License-Identifier: GPL-3.0-or-later
//
// TouchPhase: the `pane.input.touch` contact lifecycle. Shared wire
// enum so GUI and daemon spell the phase names once.

public enum TouchPhase: String, Sendable, Equatable, CaseIterable {
    case down
    case move
    case lift = "up"
}
