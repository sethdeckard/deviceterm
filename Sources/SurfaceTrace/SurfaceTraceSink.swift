// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Append-only JSONL sink. `@unchecked Sendable` is sound because the only
/// mutable state (the file handle and encoder) is touched exclusively on
/// the private serial `queue`.
public final class SurfaceTraceSink: @unchecked Sendable {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "deviceterm.surface-trace")
    private let encoder = JSONEncoder()

    /// Open `path` for appending; nil if it can't be created/opened.
    public init?(path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        if !FileManager.default.fileExists(atPath: expanded) {
            FileManager.default.createFile(atPath: expanded, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: expanded) else { return nil }
        handle.seekToEndOfFile()
        self.handle = handle
    }

    /// Build a role-suffixed sink when `baseDirectory` is a non-empty base
    /// path; nil (tracing off) otherwise. Producer and consumer pass
    /// different roles so two processes never contend on one file.
    public static func make(baseDirectory: String?, role: String) -> SurfaceTraceSink? {
        guard let base = baseDirectory, !base.isEmpty else { return nil }
        return SurfaceTraceSink(path: "\(base).\(role).jsonl")
    }

    public func record(_ row: SurfaceTraceRow) {
        queue.async { [handle, encoder] in
            guard var data = try? encoder.encode(row) else { return }
            data.append(0x0A)
            try? handle.write(contentsOf: data)
        }
    }

    /// Flush pending writes (tests read the file right after recording).
    public func drain() {
        queue.sync {}
    }
}
