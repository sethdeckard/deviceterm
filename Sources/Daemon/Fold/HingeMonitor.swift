// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

/// Watches one foldable device's hinge and reports every angle it settles on.
///
/// `xcrun devicectl device motion hinge-angle` is the only reader available.
/// CoreSimulator exposes no hinge property, and the guest helper that *drives*
/// the hinge links only the dispatch side of IOHIDEventSystem. Measured
/// against a booted Duo, that command:
///
/// - prints the device's current angle immediately on start, so an attach
///   needs no separate one-shot read;
/// - prints one line per change after that, sampling at 10 Hz and suppressing
///   anything under a degree, so an idle device costs nothing;
/// - never exits on its own. `--session-timeout` bounds the monitoring window
///   but leaves the process alive afterwards, and only the global `--timeout`
///   terminates it, non-zero. This owns the process lifetime instead: no
///   `--timeout`, and `stop()` terminates it.
///
/// Two consequences. An exit is always unexpected, so a monitor still wanted
/// replaces the reader rather than concluding anything from it. And the window
/// ending is invisible: the process stays up and simply stops printing, so the
/// window is timed here and the reader replaced when it elapses. Without that a
/// pane open longer than the window would quietly stop tracking.
///
/// This is how a fold made outside DeviceTerm becomes visible. Nothing the
/// daemon dispatches is involved, so Device Hub and `deviceterm fold` in
/// another tab are seen the same way.
///
/// `@unchecked Sendable`: the serial queue protects `process`, `buffer` and
/// `stopped`, and serializes start, restart and stop within this instance.
final class HingeMonitor: @unchecked Sendable {
    /// How long each monitoring window runs. The command accepts a day, which
    /// makes a replacement a rarity rather than routine housekeeping; the 60s
    /// default would respawn every minute for the life of a pane.
    static let defaultSessionSeconds = 86_400

    /// Pause before retrying a failed launch or an unexpected exit. A window
    /// elapsing replaces the reader immediately and does not wait this out.
    ///
    /// Long enough that a host where the reader cannot run at all retries at a
    /// readable pace rather than spinning. It retries indefinitely, so the
    /// diagnostic below is the only sign of such a host.
    static let defaultRestartDelay: DispatchTimeInterval = .seconds(2)

    private let udid: String
    private let onAngle: @Sendable (Double) -> Void
    private let sessionSeconds: Int
    private let restartDelay: DispatchTimeInterval
    private let launch: @Sendable (String, [String]) -> HingeMonitorProcess?
    private let queue: DispatchQueue
    private var process: HingeMonitorProcess?
    /// Partial trailing line from the last read, as bytes. The stream arrives
    /// in chunks that do not respect line boundaries, so a split reading would
    /// otherwise parse as two unusable halves.
    private var buffer = Data()
    private var stopped = false
    /// Bumped on every spawn, so a window timer scheduled for a reader that has
    /// since been replaced does nothing when it fires.
    private var generation: UInt64 = 0

    /// - Parameters:
    ///   - udid: the device to watch.
    ///   - onAngle: called with each valid reading, on the monitor's queue.
    ///   - sessionSeconds: length of each monitoring window. Injected so a
    ///     test does not wait out a day.
    ///   - restartDelay: pause before respawning. Injected so a test does not
    ///     wait out the production one.
    ///   - launch: spawns the reader. Injected so tests drive the parse and the
    ///     restart without a real `devicectl`.
    init(
        udid: String,
        onAngle: @escaping @Sendable (Double) -> Void,
        sessionSeconds: Int = HingeMonitor.defaultSessionSeconds,
        restartDelay: DispatchTimeInterval = HingeMonitor.defaultRestartDelay,
        launch: (@Sendable (String, [String]) -> HingeMonitorProcess?)? = nil
    ) {
        self.udid = udid
        self.onAngle = onAngle
        self.sessionSeconds = sessionSeconds
        self.restartDelay = restartDelay
        self.launch = launch ?? HingeMonitor.launchDevicectl
        self.queue = DispatchQueue(label: "com.deviceterm.daemon.hinge-monitor.\(udid)")
    }

    /// Spawn the real reader, streaming its stdout.
    ///
    /// stdout, not stderr, and no `--json-output`: with that flag these lines
    /// move to stderr and stdout carries the exit document instead.
    private static func launchDevicectl(
        _ executable: String,
        _ arguments: [String]
    ) -> HingeMonitorProcess? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        return SpawnedHingeProcess(process: process, output: pipe)
    }

    /// Begin watching. A second call while already running does nothing.
    func start() {
        queue.async { [self] in
            guard !stopped, process == nil else { return }
            spawn()
        }
    }

    /// Stop watching and terminate the reader. Idempotent, and permanent: a
    /// stopped monitor does not restart, because `stop()` means the pane it
    /// belonged to is gone.
    func stop() {
        queue.async { [self] in
            stopped = true
            process?.terminate()
            process = nil
            buffer = Data()
        }
    }

    /// Spawn a reader and wire its output. Callers hold the queue.
    private func spawn() {
        let arguments = [
            "devicectl", "device", "motion", "hinge-angle",
            "--device", udid,
            "--session-timeout", String(sessionSeconds)
        ]
        generation &+= 1
        let spawnedGeneration = generation
        guard let spawned = launch("/usr/bin/xcrun", arguments) else {
            // Retried indefinitely, so say so once per attempt: a host whose
            // `devicectl` cannot run would otherwise respawn silently for the
            // life of the pane, and a hinge that never moves looks the same as
            // a device nobody folded.
            DiagnosticLog.attach.notice("hinge reader failed to launch for \(self.udid, privacy: .public)")
            scheduleRestart()
            return
        }
        process = spawned
        scheduleWindowRefresh(for: spawnedGeneration)
        spawned.onOutput { [weak self] chunk in
            guard let self else { return }
            self.queue.async { self.consume(chunk) }
        }
        spawned.onExit { [weak self] in
            guard let self else { return }
            self.queue.async {
                guard !self.stopped else { return }
                // Always unexpected, since this reader does not exit on its
                // own. A pane that still wants an angle needs another one.
                DiagnosticLog.attach.notice(
                    "hinge reader exited for \(self.udid, privacy: .public); replacing it"
                )
                self.process = nil
                self.buffer = Data()
                self.scheduleRestart()
            }
        }
    }

    /// Replace the reader when its monitoring window elapses.
    ///
    /// The window ending produces no exit and no output, so nothing else would
    /// notice. Callers hold the queue.
    private func scheduleWindowRefresh(for spawnedGeneration: UInt64) {
        queue.asyncAfter(deadline: .now() + .seconds(sessionSeconds)) { [self] in
            guard !stopped, generation == spawnedGeneration else { return }
            process?.terminate()
            process = nil
            buffer = Data()
            spawn()
        }
    }

    /// Callers hold the queue.
    private func scheduleRestart() {
        queue.asyncAfter(deadline: .now() + restartDelay) { [self] in
            guard !stopped, process == nil else { return }
            spawn()
        }
    }

    /// Split a chunk into whole lines and report every angle in them. Callers
    /// hold the queue.
    ///
    /// Split on the newline byte before decoding. A newline cannot occur inside
    /// a UTF-8 multi-byte sequence, so a line boundary found this way is always
    /// a character boundary, which is what makes decoding each line safe where
    /// decoding an arbitrary chunk is not.
    private func consume(_ chunk: Data) {
        buffer += chunk
        let newline = UInt8(ascii: "\n")
        while let end = buffer.firstIndex(of: newline) {
            let line = buffer[buffer.startIndex..<end]
            buffer = buffer[buffer.index(after: end)...]
            guard let text = String(data: line, encoding: .utf8),
                let degrees = HingeReading.degrees(fromLine: text)
            else { continue }
            onAngle(degrees)
        }
    }
}
