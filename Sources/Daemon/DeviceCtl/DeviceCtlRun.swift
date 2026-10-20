// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// What one `devicectl` invocation produced: its exit status, the
/// contents of the `--json-output` file (nil when it wrote none), and
/// whatever it put on stderr.
struct DeviceCtlRun: Sendable {
    let status: Int32
    let json: Data?
    let stderr: String

    /// Run `xcrun` with `arguments` and wait for it, reading back the
    /// `--json-output` file at `jsonPath` and then removing it.
    ///
    /// Blocks for the whole run, so callers keep it off the cooperative pool
    /// and off any queue frames depend on. With `timeout`, a run still going
    /// after that many seconds is terminated and reports a nonzero status:
    /// right after a simulator boots, some `devicectl` commands wait minutes
    /// for CoreDevice before answering.
    static func spawn(arguments: [String], jsonPath: String, timeout: TimeInterval? = nil) -> DeviceCtlRun {
        defer { try? FileManager.default.removeItem(atPath: jsonPath) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return DeviceCtlRun(status: -1, json: nil, stderr: "\(error)")
        }
        // `xcrun` execs `devicectl` in place, so terminating it ends the run.
        let deadline = timeout.map { seconds in
            let item = DispatchWorkItem { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
            return item
        }
        defer { deadline?.cancel() }
        // Drain stderr before waiting, so a full pipe cannot deadlock it.
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return DeviceCtlRun(
            status: process.terminationStatus,
            json: FileManager.default.contents(atPath: jsonPath),
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}
