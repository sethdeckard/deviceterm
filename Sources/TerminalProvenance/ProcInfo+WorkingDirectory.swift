// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
#if canImport(Darwin)
import Darwin

/// Process-table reads that serve reporting rather than authorization.
///
/// This extension is deliberately separate from `ProcInfo.swift`: nothing here
/// is consulted by `ProvenanceMatcher` or another admission check.
extension ProcInfo {
    /// The pids whose parent is `pid`, or `[]` when none can be read.
    static func childPids(of pid: pid_t) -> [pid_t] {
        let bytes = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), nil, 0)
        guard bytes > 0 else { return [] }
        var buffer = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size)
        let written = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), &buffer, bytes)
        guard written > 0 else { return [] }
        return buffer.prefix(Int(written) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    /// `pid`'s current working directory, or nil when it cannot be read.
    ///
    /// The kernel path is returned verbatim without resolving or accessing the
    /// directory, so this remains a best-effort snapshot.
    static func currentDirectoryPath(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else {
            return nil
        }
        var pathBytes = info.pvi_cdir.vip_path
        let path = withUnsafeBytes(of: &pathBytes) { raw in
            String(bytes: raw.prefix(while: { $0 != 0 }), encoding: .utf8)
        }
        guard let path, !path.isEmpty else { return nil }
        return path
    }
}
#endif
