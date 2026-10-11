// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

/// Watches one foldable device's hinge and reports every angle it settles on.
///
/// Reads with the guest helper's `watch` mode, spawned with
/// `xcrun simctl spawn`, and falls back to
/// `xcrun devicectl device motion hinge-angle` when the guest reader cannot
/// run (`HingeReaderSource`). Both:
///
/// - print an initial angle on start, so an attach needs no separate
///   one-shot read: `devicectl` always, and the guest reader when a valid
///   current hinge event is available;
/// - print one line per change after that, so an idle device costs nothing;
/// - never exit on its own. This owns the process lifetime: `stop()`
///   terminates it, and terminating the `simctl spawn` ends the guest process
///   with it.
///
/// An exit is therefore always unexpected, and a monitor still wanted replaces
/// the reader. Failures back off: a host where the reader cannot run would
/// otherwise relaunch it every few seconds for the life of the monitor.
///
/// Silence is not a failure. The guest reader prints nothing until the device
/// has a valid hinge event, and an idle hinge prints nothing either. The guest
/// reader counts as unable to run when its helper cannot be built, or after
/// `guestFailureLimit` failures in a row with no reading between them. The
/// monitor then switches to `devicectl` for the rest of its life, if the
/// installed `devicectl` has the command. Otherwise it keeps retrying the
/// guest reader.
///
/// `devicectl` has one more quirk. `--session-timeout` bounds its monitoring
/// window but leaves the process alive and silent afterwards, so that window is
/// timed here and the reader replaced when it elapses. Without that a pane open
/// longer than the window would quietly stop tracking.
///
/// This is how a fold made outside DeviceTerm becomes visible. Nothing the
/// daemon dispatches is involved, so Device Hub and `deviceterm fold` in
/// another tab are seen the same way.
///
/// `@unchecked Sendable`: the serial queue protects `process`, `buffer`,
/// `stopped`, `failures`, `source` and `generation`, and serializes start,
/// restart and stop within this instance.
final class HingeMonitor: @unchecked Sendable {
    /// How long each `devicectl` monitoring window runs. The command accepts a
    /// day, which makes a replacement a rarity rather than routine
    /// housekeeping; the 60s default would respawn every minute for the life
    /// of a pane.
    static let defaultSessionSeconds = 86_400

    /// Pause before the first retry of a failed launch or an unexpected exit.
    /// Each further failure without a reading doubles it.
    static let defaultRestartDelay: TimeInterval = 2

    /// The longest the backoff waits between attempts, so a reader that comes
    /// good later is picked up again within a few minutes.
    static let defaultMaximumRestartDelay: TimeInterval = 300

    /// Failures in a row, with no reading between them, after which the guest
    /// reader counts as unable to run on this device.
    static let guestFailureLimit = 3

    /// The locale handed to the reader when the daemon's own environment
    /// carries none.
    ///
    /// Any UTF-8 locale will do. This one exists on every macOS install, which
    /// a generic `C.UTF-8` does not.
    static let readerLocale = "en_US.UTF-8"

    private let udid: String
    private let onAngle: @Sendable (Double) -> Void
    private let devicectlAvailable: @Sendable () -> Bool
    private let sessionSeconds: Int
    private let restartDelay: TimeInterval
    private let maximumRestartDelay: TimeInterval
    private let helperBinary: @Sendable () throws -> String
    private let launch: @Sendable (String, [String]) -> HingeMonitorProcess?
    private let queue: DispatchQueue
    private var process: HingeMonitorProcess?
    /// Partial trailing line from the last read, as bytes. The stream arrives
    /// in chunks that do not respect line boundaries, so a split reading would
    /// otherwise parse as two unusable halves.
    private var buffer = Data()
    private var stopped = false
    /// Failed launches and exits since the last reading, which set the backoff.
    private var failures = 0
    /// The reader in use. Starts as the guest helper and moves to `devicectl`
    /// at most once.
    private var source: HingeReaderSource
    /// Bumped on every spawn, so a window timer scheduled for a reader that has
    /// since been replaced does nothing when it fires.
    private var generation: UInt64 = 0

    /// - Parameters:
    ///   - udid: the device to watch.
    ///   - onAngle: called with each valid reading, on the monitor's queue.
    ///   - source: the reader to start with. Injected so a test can drive the
    ///     `devicectl` reader directly.
    ///   - devicectlAvailable: whether the fallback exists, asked only when the
    ///     guest reader cannot run. Defaults to the installed `devicectl`
    ///     (`HingeReaderSource.devicectlAvailable`). Injected so a test does
    ///     not run `xcrun`.
    ///   - sessionSeconds: length of each `devicectl` monitoring window.
    ///     Injected so a test does not wait out a day.
    ///   - restartDelay: pause before the first retry. Injected so a test does
    ///     not wait out the production one.
    ///   - maximumRestartDelay: the backoff's ceiling.
    ///   - helperBinary: the guest helper's path, building it if needed.
    ///     Injected so a test does not compile anything.
    ///   - launch: spawns the reader. Injected so tests drive the parse and the
    ///     restart without a real device.
    init(
        udid: String,
        onAngle: @escaping @Sendable (Double) -> Void,
        source: HingeReaderSource = .guestHelper,
        devicectlAvailable: (@Sendable () -> Bool)? = nil,
        sessionSeconds: Int = HingeMonitor.defaultSessionSeconds,
        restartDelay: TimeInterval = HingeMonitor.defaultRestartDelay,
        maximumRestartDelay: TimeInterval = HingeMonitor.defaultMaximumRestartDelay,
        helperBinary: (@Sendable () throws -> String)? = nil,
        launch: (@Sendable (String, [String]) -> HingeMonitorProcess?)? = nil
    ) {
        self.udid = udid
        self.onAngle = onAngle
        self.source = source
        self.devicectlAvailable = devicectlAvailable ?? { HingeReaderSource.devicectlAvailable }
        self.sessionSeconds = sessionSeconds
        self.restartDelay = restartDelay
        self.maximumRestartDelay = maximumRestartDelay
        if let helperBinary {
            self.helperBinary = helperBinary
        } else {
            let builder = FoldHelperBuilder()
            self.helperBinary = { try builder.helperBinary() }
        }
        self.launch = launch ?? HingeMonitor.launchReader
        self.queue = DispatchQueue(label: "com.deviceterm.daemon.hinge-monitor.\(udid)")
    }

    /// The environment the reader runs in.
    ///
    /// **`LANG` decides whether `devicectl` streams at all.** Without it
    /// `devicectl` block-buffers its stdout, and since this reader never exits
    /// the buffer is never flushed: a pane sees nothing for its whole life,
    /// however far the hinge moves. With it, each line arrives as it is
    /// printed. launchd starts the daemon with no `LANG`, so inheriting the
    /// environment unchanged is what silence looks like. The guest helper
    /// flushes each line itself and is indifferent to it.
    ///
    /// An existing `LANG` is left alone, so the operator's locale still
    /// decides how the reader formats what it prints. The parse handles either
    /// form: without a UTF-8 locale the degree signs and bullet are dropped,
    /// and the numbers this reads are ASCII in both.
    static func readerEnvironment(
        inheriting environment: [String: String]
    ) -> [String: String] {
        guard environment["LANG"] == nil else { return environment }
        var prepared = environment
        prepared["LANG"] = readerLocale
        return prepared
    }

    /// The wait before the next attempt after `failures` failures in a row:
    /// `base`, doubled for each failure after the first, up to `maximum`.
    static func restartDelay(
        afterFailures failures: Int,
        base: TimeInterval,
        maximum: TimeInterval
    ) -> TimeInterval {
        let doublings = Double(max(0, min(failures - 1, 32)))
        return min(base * pow(2, doublings), maximum)
    }

    /// Spawn the real reader, streaming its stdout.
    ///
    /// stdout, not stderr, and no `--json-output`: with that flag `devicectl`
    /// moves these lines to stderr and stdout carries the exit document
    /// instead.
    private static func launchReader(
        _ executable: String,
        _ arguments: [String]
    ) -> HingeMonitorProcess? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = readerEnvironment(
            inheriting: ProcessInfo.processInfo.environment
        )
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

    /// The reader's arguments for `xcrun`, or nil when the guest helper cannot
    /// be built. Callers hold the queue.
    private func readerArguments(for source: HingeReaderSource) -> [String]? {
        switch source {
        case .devicectl:
            return [
                "devicectl", "device", "motion", "hinge-angle",
                "--device", udid,
                "--session-timeout", String(sessionSeconds)
            ]

        case .guestHelper:
            do {
                let helper = try helperBinary()
                return ["simctl", "spawn", udid, helper] + FoldHelperSource.watchArguments
            } catch {
                fail("hinge reader could not be built: \(error.localizedDescription)", guestCannotRun: true)
                return nil
            }
        }
    }

    /// Spawn a reader and wire its output. Callers hold the queue.
    private func spawn() {
        guard let arguments = readerArguments(for: source) else { return }
        generation &+= 1
        let spawnedGeneration = generation
        guard let spawned = launch("/usr/bin/xcrun", arguments) else {
            fail("hinge reader failed to launch")
            return
        }
        process = spawned
        if source == .devicectl { scheduleWindowRefresh(for: spawnedGeneration) }
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
                self.process = nil
                self.buffer = Data()
                self.fail("hinge reader exited")
            }
        }
    }

    /// Replace a `devicectl` reader when its monitoring window elapses.
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

    /// Count a failure and retry: on `devicectl` at once when the guest reader
    /// cannot run and the fallback exists, and otherwise after the wait the
    /// failure earns. Callers hold the queue.
    ///
    /// - Parameter guestCannotRun: the failure alone shows the guest reader
    ///   cannot run here, without waiting for `guestFailureLimit`.
    private func fail(_ reason: String, guestCannotRun: Bool = false) {
        failures += 1
        if source == .guestHelper,
            guestCannotRun || failures >= Self.guestFailureLimit,
            devicectlAvailable() {
            DiagnosticLog.attach.notice(
                "\(reason, privacy: .public) for \(self.udid, privacy: .public); switching to devicectl"
            )
            source = .devicectl
            failures = 0
            retry(after: 0)
            return
        }
        let delay = Self.restartDelay(afterFailures: failures, base: restartDelay, maximum: maximumRestartDelay)
        DiagnosticLog.attach.notice(
            """
            \(reason, privacy: .public) for \(self.udid, privacy: .public); \
            retrying in \(Int(delay.rounded()), privacy: .public)s
            """
        )
        retry(after: delay)
    }

    /// Spawn a reader after `delay`, unless the monitor has stopped or has a
    /// reader by then. Callers hold the queue.
    private func retry(after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay) { [self] in
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
            // A valid reading resets the retry backoff.
            failures = 0
            onAngle(degrees)
        }
    }
}
