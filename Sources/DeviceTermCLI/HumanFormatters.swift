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

/// Render a `TabInfoPayload` as a column-aligned status block.
func formatTabInfo(_ payload: TabInfoPayload) -> String {
    var lines: [String] = []
    lines.append("session: \(payload.sessionId)")
    if let shortId = payload.shortId { lines.append("shortId: \(shortId)") }
    if let name = payload.name { lines.append("name:    \(name)") }
    lines.append("role:    \(payload.role)")
    lines.append("current: \(payload.isCurrent)")
    if let cwd = payload.cwd { lines.append("cwd:     \(cwd)") }
    if let label = payload.label { lines.append("label:   \(label)") }
    if payload.simPanes.isEmpty {
        lines.append("simPanes: (none)")
    } else {
        lines.append("simPanes:")
        for pane in payload.simPanes {
            let shortId = pane.shortId ?? "-"
            lines.append(
                "  \(shortId)\t\(pane.family)\t\(pane.displayName)\t\(pane.udid)"
            )
        }
    }
    return lines.joined(separator: "\n")
}

/// Render a `PaneInfoPayload` as a column-aligned status block.
func formatPaneInfo(_ payload: PaneInfoPayload) -> String {
    var lines: [String] = []
    lines.append("paneId:  \(payload.paneId)")
    lines.append("udid:    \(payload.udid)")
    if let shortId = payload.shortId { lines.append("shortId: \(shortId)") }
    if let name = payload.name { lines.append("name:    \(name)") }
    lines.append("display: \(payload.displayName)")
    lines.append("family:  \(payload.family)")
    lines.append("session: \(payload.linkedSessionId)")
    return lines.joined(separator: "\n")
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

/// Render a windows-list payload as one row per window:
/// `<marker>  <index>  <tabCount>  <selectedTabShortId>`.
func formatWindowsList(_ windows: [WindowInfoPayload]) -> String {
    windows
        .map { entry in
            let marker = entry.isKey ? "*" : " "
            let selected = entry.selectedTabShortId ?? "-"
            return "\(marker)\t\(entry.index)\t\(entry.tabCount)\t\(selected)"
        }
        .joined(separator: "\n")
}
