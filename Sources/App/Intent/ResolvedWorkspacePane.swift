// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One resolved pane of any public workspace kind.
struct ResolvedWorkspacePane {
    enum State {
        case terminal(TerminalPaneState)
        case simulator(SimPaneState)
        case device(DevicePaneState)
    }

    let windowID: WindowID
    let tabID: TabID
    let slot: PaneSlot
    let state: State

    var id: String {
        switch state {
        case let .terminal(terminal):
            terminal.sessionId

        case let .simulator(pane):
            pane.paneId

        case let .device(pane):
            pane.paneId
        }
    }

    var shortID: String? {
        switch state {
        case let .terminal(terminal):
            terminal.shortId

        case let .simulator(pane):
            pane.shortId

        case let .device(pane):
            pane.shortId
        }
    }

    var name: String? {
        switch state {
        case let .terminal(terminal):
            terminal.name

        case let .simulator(pane):
            pane.name

        case let .device(pane):
            pane.name
        }
    }
}
