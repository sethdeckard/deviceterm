// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// Candidates for the `--pane` / `--tab` / `--window` refs, read from
/// the daemon when the shell asks.
///
/// The declarations name these providers with `completion: .custom`.
/// What cannot be listed statically is the candidates, which depend on
/// what is open when the shell asks. The shell runs the binary again to
/// get them, so every path here has to fail quiet and fail fast: a
/// completion that errors puts a diagnostic in the middle of the user's
/// command line, and one that blocks hangs the keypress. Every failure
/// returns only `current`, which is always a valid ref.
enum RefCompletion {
    /// How long a completion callback will wait on the daemon.
    ///
    /// Far below the request default: this runs on a keypress, and a
    /// caller who has to wait for it would rather type the ref.
    static let timeoutSeconds = 1.0

    /// The `current` sentinel every ref accepts, offered first so it is
    /// reachable without knowing any id.
    static let sentinel = "current"

    /// Open panes, as shortIds.
    static func panes() -> [String] {
        guard let rows: [WorkspacePane] = fetch(method: .paneList, {
            try CLICommands.paneListRequest(tab: nil, all: false)
        }) else { return [sentinel] }
        return [sentinel] + rows.map(\.shortId)
    }

    /// Open tabs, as shortIds.
    static func tabs() -> [String] {
        guard let rows: [WorkspaceTab] = fetch(method: .tabList, {
            try CLICommands.tabListRequest(window: nil, all: false)
        })
        else { return [sentinel] }
        return [sentinel] + rows.map(\.shortId)
    }

    /// Open windows, as the 1-based indices `--window` accepts.
    ///
    /// `all: true` because these refs name other windows: the default
    /// returns only the window holding the calling tab, and nothing at
    /// all out of tab. The daemon still answers with the caller-visible
    /// projection, so a window holding only foreign-protected tabs is
    /// omitted either way.
    static func windows() -> [String] {
        guard let rows: [WorkspaceWindow] = fetch(
            method: .windowList,
            { try CLICommands.windowListRequest(all: true) }
        ) else { return [sentinel] }
        return [sentinel] + rows.map(\.shortId)
    }

    /// Round-trip one request under the completion deadline, or nil for
    /// any failure at all: no session, no daemon, a slow answer, a shape
    /// that will not decode.
    private static func fetch<Row: Decodable>(
        method: RPCMethod,
        _ build: () throws -> RPCEnvelope
    ) -> [Row]? {
        do {
            let data = try roundTrip(
                method: method.rawValue,
                params: paramsData(try build()),
                timeoutSeconds: timeoutSeconds
            )
            return try JSONDecoder().decode([Row].self, from: data)
        } catch {
            return nil
        }
    }
}
