// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import DaemonProtocol
import Foundation
import os

/// Reads and writes the `WorkspaceSnapshot` file under `$XDG_STATE_HOME`.
///
/// Every failure is non-fatal and degrades toward a fresh launch: a missing,
/// unreadable, malformed, or other-version file reads as nothing to restore,
/// and a failed write is dropped. Losing a layout costs the user one
/// rearrangement; refusing to launch over it would cost far more. Both are
/// logged at `.notice` so they show up in `log show`.
struct WorkspaceSnapshotStore {
    private static let log = Logger(subsystem: "com.deviceterm", category: "session-restore")

    let path: String

    init(path: String = Self.defaultPath()) {
        self.path = path
    }

    /// The snapshot path for this app.
    ///
    /// An app built inside a checkout (its executable under a `.build`
    /// directory) gets a file of its own, named for that checkout, so a
    /// development build and the installed app never restore each other's
    /// windows and simulator panes, and neither do two worktrees.
    static func defaultPath(
        executablePath: String? = Bundle.main.executablePath,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        XDGPaths.deviceTermWorkspaceSnapshot(
            fileName: fileName(executablePath: executablePath),
            environment: environment
        )
    }

    /// `workspace.json`, or `workspace-<checkout>.json` for an executable
    /// under a checkout's `.build` directory, where `<checkout>` is a short
    /// digest of the checkout root.
    static func fileName(executablePath: String?) -> String {
        guard let executablePath else { return "workspace.json" }
        let resolved = (executablePath as NSString).resolvingSymlinksInPath
        guard let range = resolved.range(of: "/.build/") else { return "workspace.json" }
        let checkout = String(resolved[..<range.lowerBound])
        let digest = SHA256.hash(data: Data(checkout.utf8))
            .prefix(6)
            .map { String(format: "%02x", $0) }
            .joined()
        return "workspace-\(digest).json"
    }

    /// The encoded form `write` puts on disk. Sorted keys, so an unchanged
    /// layout encodes to identical bytes and the writer can skip it.
    static func encode(_ snapshot: WorkspaceSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(snapshot)
    }

    /// The snapshot `data` holds, or nil when it is malformed or was written
    /// by another format version.
    static func decode(_ data: Data) -> WorkspaceSnapshot? {
        guard let snapshot = try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data) else {
            return nil
        }
        guard snapshot.version == WorkspaceSnapshot.currentVersion else { return nil }
        return snapshot
    }

    /// The saved snapshot, or nil when there is nothing usable to restore.
    func read() -> WorkspaceSnapshot? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard let data = FileManager.default.contents(atPath: path) else {
            Self.log.notice("workspace snapshot unreadable at \(path, privacy: .public)")
            return nil
        }
        guard let snapshot = Self.decode(data) else {
            Self.log.notice(
                "workspace snapshot malformed or another version at \(path, privacy: .public)"
            )
            return nil
        }
        return snapshot
    }

    /// Replace the file with `data`, creating its directory if needed. A
    /// failure is logged and dropped.
    func write(_ data: Data) {
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            Self.log.notice(
                "workspace snapshot write failed at \(path, privacy: .public): \(error, privacy: .public)"
            )
        }
    }
}
