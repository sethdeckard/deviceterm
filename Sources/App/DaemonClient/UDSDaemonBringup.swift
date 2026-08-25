// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
#if canImport(Darwin)
import Darwin
#endif

@MainActor
enum UDSDaemonBringup {
    /// Spawn the daemon binary if no UDS at `socketPath` accepts, then
    /// poll-connect with backoff. Returns a wrapped connection.
    static func bringUp(socketPath: String) async throws -> UDSDaemonConnection {
        if let fd = tryConnect(socketPath) {
            return UDSDaemonConnection(fd: fd)
        }
        guard let binary = daemonBinaryPath() else {
            throw DaemonClientError.transport(
                "smoke fallback: could not locate deviceterm-daemon binary"
            )
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        do {
            try proc.run()
        } catch {
            throw DaemonClientError.transport("smoke fallback spawn: \(error)")
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let fd = tryConnect(socketPath) {
                return UDSDaemonConnection(fd: fd)
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        throw DaemonClientError.transport("smoke fallback: timed out connecting at \(socketPath)")
    }

    private static func tryConnect(_ path: String) -> Int32? {
        try? UDSClientSocket.connect(to: path)
    }

    /// Smoke-mode daemon discovery. Honors `DEVICETERM_DAEMON_PATH`
    /// override; otherwise looks inside the .app bundle.
    private static func daemonBinaryPath() -> String? {
        if let env = ProcessInfo.processInfo.environment[DeviceTermEnv.daemonPath],
            !env.isEmpty {
            return env
        }
        let exe = Bundle.main.executableURL?.resolvingSymlinksInPath()
        if let exe, exe.path.contains(".app/") {
            let appRoot = exe
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let helper = appRoot
                .appendingPathComponent(
                    "Contents/Library/LoginItems/deviceterm-daemon.app"
                    + "/Contents/MacOS/deviceterm-daemon"
                )
            if FileManager.default.isExecutableFile(atPath: helper.path) {
                return helper.path
            }
        }
        return SessionEnvironment.locateSibling(named: "deviceterm-daemon")
    }
}
