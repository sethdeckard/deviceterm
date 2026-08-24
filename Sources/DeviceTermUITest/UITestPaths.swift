// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation

/// Resolves the harness's socket path (shared by resident + client).
enum UITestPaths {
    /// `$DEVICETERM_UITEST_SOCK` if set, else
    /// `~/Library/Caches/deviceterm/uitest.sock`.
    static var socketPath: String {
        let override = ProcessInfo.processInfo.environment["DEVICETERM_UITEST_SOCK"]
        if let override, !override.isEmpty {
            return override
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let base = caches?.appendingPathComponent("deviceterm", isDirectory: true)
        return base?.appendingPathComponent("uitest.sock").path ?? "/tmp/deviceterm-uitest.sock"
    }

    static func ensureParentDirectory() throws {
        let directory = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
    }
}
