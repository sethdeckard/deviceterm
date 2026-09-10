// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
#if canImport(Darwin)
import Darwin
#endif

func envValue(_ name: String) -> String? {
    guard let raw = getenv(name) else { return nil }
    return String(cString: raw)
}

func writeStderr(_ message: String) {
    FileHandle.standardError.write(message.data(using: .utf8) ?? Data())
}

/// Spawn `/usr/bin/which <command>` and return the resolved absolute
/// path, or nil if `which` didn't find anything. Used by `deviceterm
/// doctor` to check whether `xcrun` resolves to the per-session shim.
/// The shim has to be first on PATH for boots to be intercepted.
func lookupOnPath(_ command: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    process.arguments = [command]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
    } catch {
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let resolved = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return (resolved?.isEmpty == false) ? resolved : nil
}

/// Resolve the daemon socket path from the env the tab shell carries
/// (`DEVICETERM_DAEMON_SOCK`), else the canonical default location.
func daemonSocketPath() -> String {
    if let sock = envValue(DeviceTermEnv.daemonSock), !sock.isEmpty { return sock }
    let appSupport = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    ).first
    return appSupport?
        .appendingPathComponent("deviceterm/daemon.sock")
        .path ?? "/tmp/deviceterm-daemon.sock"
}
