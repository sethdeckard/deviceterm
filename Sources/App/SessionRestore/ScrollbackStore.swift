// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import os

/// Keeps the terminal scrollback a restored layout replays: one file per
/// terminal under `$XDG_STATE_HOME/deviceterm/scrollback`, named by a random
/// id that the saved layout's terminal leaf records.
///
/// Scrollback holds whatever a terminal printed, secrets included, so the
/// directory is created `0700` and each file `0600`. The ids come back from
/// the layout file, which anything running as the user can edit, so only a
/// UUID is accepted as one, and a file larger than `maxBytes` isn't read.
///
/// Failures degrade the way `WorkspaceSnapshotStore`'s do: a file that can't
/// be written isn't recorded, and one that can't be read restores no
/// scrollback. Write failures and existing files that cannot be loaded
/// within the size limit are logged at `.notice`.
struct ScrollbackStore {
    /// Rows saved per terminal.
    static let maxRows = 10_000

    /// Maximum file size accepted during restore.
    static let maxBytes = 16 * 1_024 * 1_024

    private static let log = Logger(subsystem: "com.deviceterm", category: "session-restore")

    let directory: String

    init(directory: String = Self.defaultDirectory()) {
        self.directory = directory
    }

    /// `scrollback`, or `scrollback-<checkout>` for an app built in a
    /// checkout, matching the workspace file's name (see
    /// `WorkspaceSnapshotStore.instanceSuffix`).
    static func defaultDirectory(
        executablePath: String? = Bundle.main.executablePath,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let suffix = WorkspaceSnapshotStore.instanceSuffix(executablePath: executablePath)
        return XDGPaths.deviceTermScrollback(
            directoryName: "scrollback\(suffix)",
            environment: environment
        )
    }

    /// Save `text` and return the id that names it, or nil when it couldn't
    /// be written.
    func write(_ text: String) -> String? {
        let id = UUID().uuidString
        do {
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // Tighten a directory an earlier run created more loosely.
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
            let path = self.path(for: id)
            try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return id
        } catch {
            Self.log.notice("scrollback write failed: \(error, privacy: .public)")
            return nil
        }
    }

    /// The text saved under `id`, or nil when `id` isn't a UUID or the file
    /// is missing, unreadable, too large, or not UTF-8.
    func read(_ id: String) -> String? {
        guard UUID(uuidString: id) != nil else { return nil }
        let path = self.path(for: id)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let size = attributes[.size] as? Int, size <= Self.maxBytes,
            let data = FileManager.default.contents(atPath: path) else {
            if FileManager.default.fileExists(atPath: path) {
                Self.log.notice("scrollback unreadable or oversized: \(id, privacy: .public)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// The output each terminal in `snapshot` shows above its first prompt,
    /// keyed by the scrollback id its leaf records. An id with no readable
    /// file, or whose file holds nothing to show, is left out.
    func replayOutputs(for snapshot: WorkspaceSnapshot) -> [String: String] {
        var outputs: [String: String] = [:]
        for tab in snapshot.windows.flatMap(\.tabs) {
            for case let .terminal(terminal) in WorkspaceRestoreLayout.leaves(tab.layout) {
                guard let id = terminal.scrollback, outputs[id] == nil,
                    let saved = read(id),
                    let output = ScrollbackReplay.output(from: saved) else { continue }
                outputs[id] = output
            }
        }
        return outputs
    }

    /// Delete every saved file whose id isn't in `kept`.
    func removeAll(except kept: Set<String>) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        for name in names {
            let id = (name as NSString).deletingPathExtension
            guard !kept.contains(id) else { continue }
            try? FileManager.default.removeItem(atPath: (directory as NSString).appendingPathComponent(name))
        }
    }

    /// Delete the directory and everything in it.
    func removeDirectory() {
        guard FileManager.default.fileExists(atPath: directory) else { return }
        do {
            try FileManager.default.removeItem(atPath: directory)
        } catch {
            Self.log.notice("scrollback directory removal failed: \(error, privacy: .public)")
        }
    }

    private func path(for id: String) -> String {
        (directory as NSString).appendingPathComponent("\(id).vt")
    }
}
