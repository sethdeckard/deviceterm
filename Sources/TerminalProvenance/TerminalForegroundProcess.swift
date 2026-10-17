// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
#if canImport(Darwin)
import Darwin

/// Names the process a terminal is running in its foreground.
///
/// Reporting only, like `TerminalWorkingDirectory`: no authorization path
/// consults it, and a wrong or missing answer can only misreport the field.
/// `proc_pidinfo` refuses a cross-uid read, so a root-owned foreground process
/// such as `sudo` yields nil rather than a name.
public enum TerminalForegroundProcess {
    /// The kernel name of `foregroundPid`, or nil when it cannot be read or is
    /// no longer controlled by `ttyName`.
    ///
    /// The terminal surface supplies the pid, and by the time it is read the
    /// process may have exited and the pid been recycled. Requiring the process
    /// to still sit on the named terminal keeps a recycled pid elsewhere on the
    /// machine from lending its name.
    public static func name(foregroundPid: pid_t, ttyName: String) -> String? {
        var ttyStat = stat()
        guard stat(ttyName, &ttyStat) == 0,
            (ttyStat.st_mode & S_IFMT) == S_IFCHR
        else { return nil }
        return name(of: foregroundPid, controlledBy: ttyStat.st_rdev)
    }

    /// The kernel name of `pid` when its controlling terminal is `ttyDevice`.
    ///
    /// Prefers `pbi_name`, which holds up to 2 × `MAXCOMLEN` bytes, and falls
    /// back to the shorter `pbi_comm` when the kernel left it empty.
    static func name(of pid: pid_t, controlledBy ttyDevice: dev_t) -> String? {
        guard let info = ProcInfo.bsdInfo(of: pid),
            dev_t(bitPattern: info.e_tdev) == ttyDevice
        else { return nil }
        return string(from: info.pbi_name) ?? string(from: info.pbi_comm)
    }

    /// A NUL-terminated C character array as a Swift string, or nil when it is
    /// empty or not UTF-8.
    private static func string<T>(from tuple: T) -> String? {
        withUnsafeBytes(of: tuple) { raw in
            let bytes = raw.prefix { $0 != 0 }
            guard !bytes.isEmpty else { return nil }
            return String(bytes: bytes, encoding: .utf8)
        }
    }
}
#endif
