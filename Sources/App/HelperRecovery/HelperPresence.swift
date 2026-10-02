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
    /// The scan couldn't complete, or a live process could be identified by
    /// neither path nor name. Treat it as possibly running: an ambiguous answer
    /// must never license a rebuild.
    case unknown

    /// What the scan could learn about one live process.
    enum Sighting: Equatable {
        /// Its executable's path.
        case path(String)
        /// Only its name, as `proc_name` reports it: the executable's name at
        /// exec, cut to 31 bytes. A process whose binary was deleted or
        /// replaced after launch has no readable path but keeps its name.
        case name(String)
        /// Neither.
        case unreadable
    }

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
        var sightings: [Sighting] = []
        for pid in pids {
            if let path = executablePath(of: pid) {
                sightings.append(.path(path))
            } else if let name = name(of: pid) {
                sightings.append(.name(name))
            } else if kill(pid, 0) == 0 || errno != ESRCH {
                // Alive, but unreadable. Skip processes that exited after
                // enumeration; they are no longer running.
                sightings.append(.unreadable)
            }
        }
        return classify(sightings, executableName: executableName)
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

    /// One sighting per live process. A match anywhere means running;
    /// otherwise an unreadable process leaves the answer unknown.
    static func classify(_ sightings: [Sighting], executableName: String) -> Self {
        if sightings.contains(where: { isHelper($0, executableName: executableName) }) {
            return .running
        }
        return sightings.contains(.unreadable) ? .unknown : .notRunning
    }

    /// A name matches when it is the executable's name, or a cut-short prefix
    /// of one too long to fit.
    static func isHelper(_ sighting: Sighting, executableName: String) -> Bool {
        switch sighting {
        case let .path(path):
            return (path as NSString).lastPathComponent == executableName

        case let .name(name):
            return name == executableName
                || (name.utf8.count >= nameLimit && executableName.hasPrefix(name))

        case .unreadable:
            return false
        }
    }
}

private extension HelperPresence {
    /// The longest name `proc_name` reports: the kernel's `2 * MAXCOMLEN`
    /// byte name field, less its terminator.
    static var nameLimit: Int { 2 * Int(MAXCOMLEN) - 1 }

    static func name(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(bytes: buffer.prefix(Int(length)), encoding: .utf8)
    }

    static func executablePath(of pid: pid_t) -> String? {
        // `PROC_PIDPATHINFO_MAXSIZE`, which doesn't import into Swift.
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(bytes: buffer.prefix(Int(length)), encoding: .utf8)
    }
}
