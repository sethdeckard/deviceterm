// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

/// Whether any process of this user is running the helper executable.
///
/// A process scan rather than a probe of the helper's socket, because the
/// helper picks that socket from launchd's environment, which the GUI can't
/// see, so no path the GUI computes is guaranteed to be the one a running
/// helper listens on. Any copy counts, whichever checkout or bundle it came
/// from: unregistering stops the job launchd is running, and its sessions with
/// it.
///
/// This is a point-in-time result; a helper can start and accept sessions
/// after the scan.
enum HelperPresence: Equatable {
    case running
    case notRunning
    /// The scan couldn't complete, or a live process's executable couldn't be
    /// read. Treat it as possibly running: an ambiguous answer must never
    /// license a rebuild.
    case unknown

    /// The helper's executable name, the last component of the agent plist's
    /// `BundleProgram`, or nil when the plist doesn't carry one.
    static func executableName(fromAgentPlist plist: Data) -> String? {
        guard let object = try? PropertyListSerialization.propertyList(from: plist, format: nil),
            let dictionary = object as? [String: Any],
            let program = dictionary["BundleProgram"] as? String
        else { return nil }
        let name = (program as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    /// Scan this user's processes for one running `executableName`.
    static func probe(executableName: String) -> Self {
        let uid = UInt32(getuid())
        let pids = completeList { buffer, bytes in
            proc_listpids(UInt32(PROC_UID_ONLY), uid, buffer, bytes)
        }
        guard let pids else { return .unknown }
        var paths: [String?] = []
        for pid in pids {
            if let path = executablePath(of: pid) {
                paths.append(path)
            } else if kill(pid, 0) == 0 || errno != ESRCH {
                // Alive, but unreadable. Skip processes that exited after
                // enumeration; they are no longer running.
                paths.append(nil)
            }
        }
        return classify(executablePaths: paths, executableName: executableName)
    }

    /// The full list `list` produces, or nil when one couldn't be had.
    ///
    /// `list` follows `proc_listpids`: a nil buffer asks for the size needed,
    /// and a real one returns the bytes filled. A list that fills its buffer may
    /// have been cut short, and the helper could be among the processes cut, so
    /// a full buffer is retried with twice the room rather than trusted.
    static func completeList(
        _ list: (UnsafeMutableRawPointer?, Int32) -> Int32
    ) -> [pid_t]? {
        let stride = MemoryLayout<pid_t>.stride
        let needed = list(nil, 0)
        guard needed > 0 else { return nil }
        // Headroom for processes started between the calls.
        var capacity = Int(needed) / stride + 64
        for _ in 0..<4 {
            var pids = [pid_t](repeating: 0, count: capacity)
            let filled = pids.withUnsafeMutableBytes { list($0.baseAddress, Int32($0.count)) }
            guard filled > 0 else { return nil }
            let count = Int(filled) / stride
            if count < capacity {
                return pids.prefix(count).filter { $0 > 0 }
            }
            capacity *= 2
        }
        return nil
    }

    /// `executablePaths` holds one entry per live process, nil where its path
    /// couldn't be read. A match anywhere means running; otherwise an unread
    /// path leaves the answer unknown.
    static func classify(executablePaths: [String?], executableName: String) -> Self {
        if executablePaths.contains(where: { $0.map { ($0 as NSString).lastPathComponent } == executableName }) {
            return .running
        }
        return executablePaths.contains(where: { $0 == nil }) ? .unknown : .notRunning
    }
}

private extension HelperPresence {
    static func executablePath(of pid: pid_t) -> String? {
        // `PROC_PIDPATHINFO_MAXSIZE`, which doesn't import into Swift.
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(bytes: buffer.prefix(Int(length)), encoding: .utf8)
    }
}
