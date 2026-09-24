// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The `sim` / `device` type label for a pane row, read from its
/// backend-neutral `target`. Defaults to `sim` when `target` is absent,
/// which is a valid shape during daemon-version skew.
func paneTypeLabel(_ entry: PanesListEntry) -> String {
    switch entry.target {
    case .device:
        return "device"

    case .sim, nil:
        return "sim"
    }
}

/// Render a pane roster as a `<shortId>  <type>  <key>` block, used
/// in the ambiguity / multi-pane error messages so the user sees both
/// sims and physical devices with their resolvable refs.
func paneRosterLines(_ panes: [PanesListEntry]) -> String {
    panes
        .map { entry in
            let shortId = entry.shortId ?? entry.paneId
            return "  \(shortId)\t\(paneTypeLabel(entry))\t\(entry.udid)"
        }
        .joined(separator: "\n")
}

/// Render the `devices.list` roster as one row per device:
/// `<id>\t<kind>\t<name>\t<model>\t<os>\t<state>\t<attachment>`. `model`
/// and `os` are physical-device only (sims show `-`) and disambiguate
/// two connected devices that share a name. The attachment column reads
/// `attached` or `available`, and an owner session the caller may see
/// appears as `attached:<sessionId>`. A device held only by a protected
/// tab the caller cannot see arrives as unattached, so it reads
/// `available` here.
func formatDeviceRoster(_ roster: [DeviceRosterEntry]) -> String {
    roster
        .map { entry in
            let name = entry.name ?? "-"
            let model = entry.model ?? "-"
            let osVersion = entry.osVersion ?? "-"
            let state = entry.state ?? "-"
            let attachment: String
            if entry.attached {
                attachment = entry.ownerSessionId.map { "attached:\($0)" } ?? "attached"
            } else {
                attachment = "available"
            }
            return "\(entry.id)\t\(entry.kind.rawValue)\t\(name)\t\(model)"
                + "\t\(osVersion)\t\(state)\t\(attachment)"
        }
        .joined(separator: "\n")
}

/// Render public workspace windows as stable tab-separated rows.
func formatWorkspaceWindows(_ windows: [WorkspaceWindow]) -> String {
    windows
        .map { window in
            let marker = window.current ? "*" : " "
            let name = window.name ?? "-"
            let selected = window.selectedTabId ?? "-"
            return "\(marker)\t\(window.shortId)\t\(name)\t\(window.tabCount)\t\(selected)"
        }
        .joined(separator: "\n")
}

/// Render public workspace tabs as stable tab-separated rows.
func formatWorkspaceTabs(_ tabs: [WorkspaceTab]) -> String {
    tabs
        .map { tab in
            let marker = tab.current ? "*" : " "
            let name = tab.name ?? "-"
            return "\(marker)\t\(tab.shortId)\t\(name)\t\(tab.title)\t\(tab.paneCount)\t\(tab.state.rawValue)"
        }
        .joined(separator: "\n")
}

/// Render public workspace panes as stable tab-separated rows.
func formatWorkspacePanes(_ panes: [WorkspacePane]) -> String {
    panes
        .map { pane in
            let marker = pane.current ? "*" : " "
            let name = pane.name ?? "-"
            return "\(marker)\t\(pane.shortId)\t\(pane.kind.rawValue)\t\(name)\t\(pane.id)"
        }
        .joined(separator: "\n")
}

func formatWorkspaceWindowDetail(_ detail: WorkspaceWindowDetail) -> String {
    var lines = [
        "window:  \(detail.window.id)",
        "shortId: \(detail.window.shortId)",
        "index:   \(detail.window.index)",
        "focused: \(detail.window.focused)",
        "tabs:"
    ]
    lines.append(contentsOf: formatWorkspaceTabs(detail.tabs).split(separator: "\n").map(String.init))
    return lines.joined(separator: "\n")
}

func formatWorkspaceTabDetail(_ detail: WorkspaceTabDetail) -> String {
    var lines = [
        "tab:       \(detail.tab.id)",
        "shortId:   \(detail.tab.shortId)",
        "window:    \(detail.tab.windowId)",
        "title:     \(detail.tab.title)",
        "state:     \(detail.tab.state.rawValue)",
        "protected: \(detail.tab.protected)",
        "panes:"
    ]
    lines.append(contentsOf: formatWorkspacePanes(detail.panes).split(separator: "\n").map(String.init))
    return lines.joined(separator: "\n")
}

func formatWorkspacePane(_ pane: WorkspacePane) -> String {
    var lines = [
        "pane:    \(pane.id)",
        "shortId: \(pane.shortId)",
        "kind:    \(pane.kind.rawValue)",
        "tab:     \(pane.tabId)",
        "focused: \(pane.focused)"
    ]
    if let name = pane.name { lines.append("name:    \(name)") }
    if let terminal = pane.terminal {
        lines.append("session: \(terminal.sessionId)")
        lines.append("title:   \(terminal.title)")
        if let tty = terminal.tty { lines.append("tty:     \(tty)") }
        if let cwd = terminal.cwd { lines.append("cwd:     \(cwd)") }
    }
    if let simulator = pane.simulator {
        lines.append("udid:    \(simulator.udid)")
        lines.append("display: \(simulator.displayName)")
    }
    if let device = pane.device {
        lines.append("device:  \(device.deviceId)")
        lines.append("display: \(device.displayName)")
    }
    return lines.joined(separator: "\n")
}

func formatWorkspaceMutation(_ receipt: WorkspaceMutationReceipt) -> String {
    var fields = ["ok"]
    if let window = receipt.window { fields.append("window=\(window.shortId)") }
    if let tab = receipt.tab { fields.append("tab=\(tab.shortId)") }
    if let pane = receipt.pane { fields.append("pane=\(pane.shortId)") }
    if let closed = receipt.closed { fields.append("closed=\(closed.resource)") }
    if let mode = receipt.mode { fields.append("mode=\(mode.rawValue)") }
    if let bytes = receipt.bytes { fields.append("bytes=\(bytes)") }
    if let delay = receipt.typeDelayMs { fields.append("typeDelayMs=\(delay)") }
    return fields.joined(separator: " ")
}

/// One line per configured automation program, in file order.
///
/// `state` leads because it is the answer to why someone ran this. The
/// trailing reason appears only when supervision has something to say, so
/// a healthy program renders as one short line.
func formatAutomationPrograms(_ programs: [AutomationProgramStatus]) -> String {
    guard !programs.isEmpty else { return "no automation programs configured" }
    return programs.map { program in
        var fields = ["\(program.state.rawValue)", program.name]
        if let pid = program.pid { fields.append("pid=\(pid)") }
        if program.restarts > 0 { fields.append("restarts=\(program.restarts)") }
        if let tab = program.tabId { fields.append("tab=\(tab)") }
        if let seen = program.lastSeenRunning { fields.append("lastSeenRunning=\(seen)") }
        if let error = program.lastError { fields.append("(\(error))") }
        return fields.joined(separator: " ")
    }
    .joined(separator: "\n")
}
