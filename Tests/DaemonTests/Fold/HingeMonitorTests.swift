// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import Foundation
import Testing

/// `HingeMonitor`'s process handling, driven through a fake reader so no
/// device is touched and no helper is built.
///
/// The reader never exits on its own, so an exit is unexpected and a monitor
/// still wanted replaces it, backing off while it keeps failing; a guest
/// reader that cannot run gives way to `devicectl` where that exists; a
/// `devicectl` window ends without an exit or any output, so it has to be
/// timed; and output arrives in chunks that ignore line boundaries, so a
/// reading split across two reads still has to parse.
struct HingeMonitorTests {
    private static let validLine = "angle 42.0\n"

    @Test("reports every angle in the stream")
    func reportsAngles() async throws {
        let collected = Collected()
        let readers = Readers()
        let monitor = HingeMonitor(
            udid: "U",
            onAngle: { collected.append($0) },
            source: .guestHelper,
            restartDelay: 0.01,
            helperBinary: { "/test/fold-helper" },
            launch: { _, _ in readers.make() }
        )
        monitor.start()
        let reader = try #require(await readers.first())
        reader.emit(Self.validLine)
        #expect(await collected.reaches([42.0]))
        monitor.stop()
    }

    @Test("reports each orientation the reader prints, apart from the angles")
    func reportsOrientations() async throws {
        // A closed foldable's rotation changes nothing else the daemon can
        // see, so these lines are its only word of one.
        let angles = Collected()
        let orientations = CollectedOrientations()
        let readers = Readers()
        let monitor = HingeMonitor(
            udid: "U",
            onAngle: { angles.append($0) },
            onOrientation: { orientations.append($0) },
            source: .guestHelper,
            restartDelay: 0.01,
            helperBinary: { "/test/fold-helper" },
            launch: { _, _ in readers.make() }
        )
        monitor.start()
        let reader = try #require(await readers.first())
        reader.emit("orientation landscape-right\nangle 0.0\norientation pud\norientation faceup\n")
        #expect(await orientations.reaches([.landscapeRight, .portraitUpsideDown]))
        #expect(await angles.reaches([0.0]))
        monitor.stop()
    }

    @Test("a reading split across two reads still parses")
    func reassemblesASplitLine() async throws {
        let collected = Collected()
        let readers = Readers()
        let monitor = HingeMonitor(
            udid: "U",
            onAngle: { collected.append($0) },
            source: .guestHelper,
            restartDelay: 0.01,
            helperBinary: { "/test/fold-helper" },
            launch: { _, _ in readers.make() }
        )
        monitor.start()
        let reader = try #require(await readers.first())
        // The pipe splits wherever it likes. Halving mid-number is the case
        // that would otherwise parse as two unusable fragments.
        let line = Self.validLine
        let cut = line.index(line.startIndex, offsetBy: 8)
        reader.emit(String(line[line.startIndex..<cut]))
        reader.emit(String(line[cut...]))
        #expect(await collected.reaches([42.0]))
        monitor.stop()
    }

    @Test("a partial line with no newline is held, not parsed")
    func holdsAPartialLine() async throws {
        let collected = Collected()
        let readers = Readers()
        let monitor = HingeMonitor(
            udid: "U",
            onAngle: { collected.append($0) },
            source: .guestHelper,
            restartDelay: 0.01,
            helperBinary: { "/test/fold-helper" },
            launch: { _, _ in readers.make() }
        )
        monitor.start()
        let reader = try #require(await readers.first())
        reader.emit(String(Self.validLine.dropLast()))
        // Give the queue a chance to do the wrong thing before confirming it
        // did not.
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(collected.values().isEmpty)
        monitor.stop()
    }

    @Test("an exit brings up another reader")
    func restartsAfterAnExit() async throws {
        let readers = Readers()
        let monitor = HingeMonitor(
            udid: "U",
            onAngle: { _ in },
            source: .guestHelper,
            devicectlAvailable: { false },
            restartDelay: 0.01,
            helperBinary: { "/test/fold-helper" },
            launch: { _, _ in readers.make() }
        )
        monitor.start()
        let first = try #require(await readers.first())
        // An unexpected exit. The reader does not end on its own, so this is a
        // reader that died and has to be replaced.
        first.finish()
        #expect(await readers.reachesCount(2))
        monitor.stop()
    }

    @Test("a stopped monitor never spawns again")
    func doesNotRestartAfterStop() async throws {
        let readers = Readers()
        let monitor = HingeMonitor(
            udid: "U",
            onAngle: { _ in },
            source: .guestHelper,
            restartDelay: 0.01,
            helperBinary: { "/test/fold-helper" },
            launch: { _, _ in readers.make() }
        )
        monitor.start()
        let first = try #require(await readers.first())
        monitor.stop()
        first.finish()
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(readers.count() == 1)
        #expect(first.wasTerminated())
    }

    @Test("starting twice spawns one reader")
    func startIsIdempotent() async throws {
        let readers = Readers()
        let monitor = HingeMonitor(
            udid: "U",
            onAngle: { _ in },
            source: .guestHelper,
            restartDelay: 0.01,
            helperBinary: { "/test/fold-helper" },
            launch: { _, _ in readers.make() }
        )
        monitor.start()
        monitor.start()
        _ = try #require(await readers.first())
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(readers.count() == 1)
        monitor.stop()
    }

    @Test("the reader is the guest helper's watch mode, through simctl")
    func spawnsTheGuestWatcher() async throws {
        let calls = Calls()
        let readers = Readers()
        let monitor = HingeMonitor(
            udid: "U1",
            onAngle: { _ in },
            source: .guestHelper,
            restartDelay: 0.01,
            helperBinary: { "/cache/fold-helper" },
            launch: { executable, arguments in
                calls.record(executable, arguments)
                return readers.make()
            }
        )
        monitor.start()
        _ = try #require(await readers.first())
        #expect(calls.first()?.0 == "/usr/bin/xcrun")
        #expect(calls.first()?.1 == ["simctl", "spawn", "U1", "/cache/fold-helper", "watch"])
        monitor.stop()
    }

    @Test("a devicectl host reads through devicectl device motion")
    func spawnsDevicectlWhereItHasTheCommand() async throws {
        let calls = Calls()
        let readers = Readers()
        let monitor = HingeMonitor(
            udid: "U1",
            onAngle: { _ in },
            source: .devicectl,
            sessionSeconds: 600,
            restartDelay: 0.01,
            helperBinary: { "/test/fold-helper" },
            launch: { executable, arguments in
                calls.record(executable, arguments)
                return readers.make()
            }
        )
        monitor.start()
        _ = try #require(await readers.first())
        #expect(calls.first()?.1 == [
            "devicectl", "device", "motion", "hinge-angle", "--device", "U1", "--session-timeout", "600"
        ])
        monitor.stop()
    }

    @Test("a devicectl reader is replaced when its window elapses")
    func replacesTheDevicectlReaderWhenTheWindowEnds() async throws {
        let readers = Readers()
        let monitor = HingeMonitor(
            udid: "U",
            onAngle: { _ in },
            source: .devicectl,
            sessionSeconds: 0,
            restartDelay: 0.01,
            helperBinary: { "/test/fold-helper" },
            launch: { _, _ in readers.make() }
        )
        monitor.start()
        let first = try #require(await readers.first())
        // The window ending produces no exit and no output, so without a timer
        // the stream goes quiet and nothing notices.
        #expect(await readers.reachesCount(2))
        #expect(first.wasTerminated())
        monitor.stop()
    }

    @Test("a devicectl line cut inside a multi-byte character still parses")
    func reassemblesASplitMultiByteCharacter() async throws {
        let collected = Collected()
        let readers = Readers()
        let monitor = HingeMonitor(
            udid: "U",
            onAngle: { collected.append($0) },
            source: .devicectl,
            restartDelay: 0.01,
            helperBinary: { "/test/fold-helper" },
            launch: { _, _ in readers.make() }
        )
        monitor.start()
        let reader = try #require(await readers.first())
        // `°` is two bytes and `•` is three. Cutting between the bytes of one
        // is what a decode-per-chunk drops, taking the reading with it.
        let bytes = Data("• +1.000s : Angle: 42.0°  Mech: 42.0°  AngleValid:Y\n".utf8)
        let degreeSign = Data("°".utf8)
        let inside = try #require(bytes.firstIndex(of: degreeSign[degreeSign.startIndex]))
        reader.emit(bytes[bytes.startIndex...inside])
        reader.emit(bytes[bytes.index(after: inside)...])
        #expect(await collected.reaches([42.0]))
        monitor.stop()
    }

    @Test("a helper that cannot be built is retried")
    func retriesAnUnbuildableHelper() async {
        let attempts = Counter()
        let readers = Readers()
        let monitor = HingeMonitor(
            udid: "U",
            onAngle: { _ in },
            source: .guestHelper,
            devicectlAvailable: { false },
            restartDelay: 0.01,
            helperBinary: {
                if attempts.bump() == 1 { throw CocoaError(.fileNoSuchFile) }
                return "/test/fold-helper"
            },
            launch: { _, _ in readers.make() }
        )
        monitor.start()
        #expect(await readers.reachesCount(1))
        #expect(attempts.value() >= 2)
        monitor.stop()
    }

    @Test("retries back off while the reader keeps failing", arguments: [
        (1, 2.0), (2, 4.0), (3, 8.0), (8, 256.0), (9, 300.0), (40, 300.0)
    ])
    func retriesBackOff(failures: Int, expected: TimeInterval) {
        // A reader that cannot run would otherwise relaunch every couple of
        // seconds for the life of the pane.
        #expect(HingeMonitor.restartDelay(afterFailures: failures, base: 2, maximum: 300) == expected)
    }

    @Test("a launch that fails is retried")
    func retriesAFailedLaunch() async {
        let attempts = Counter()
        let readers = Readers()
        let monitor = HingeMonitor(
            udid: "U",
            onAngle: { _ in },
            source: .guestHelper,
            devicectlAvailable: { false },
            restartDelay: 0.01,
            helperBinary: { "/test/fold-helper" },
            launch: { _, _ in
                // Fails once, then succeeds: a failed launch has to be retried
                // rather than given up on.
                attempts.bump() == 1 ? nil : readers.make()
            }
        )
        monitor.start()
        #expect(await readers.reachesCount(1))
        #expect(attempts.value() >= 2)
        monitor.stop()
    }

    @Test("a monitor starts on the guest reader without asking devicectl")
    func startsOnTheGuestReader() async throws {
        let calls = Calls()
        let asked = Counter()
        let readers = Readers()
        let monitor = HingeMonitor(
            udid: "U1",
            onAngle: { _ in },
            devicectlAvailable: {
                _ = asked.bump()
                return true
            },
            restartDelay: 0.01,
            helperBinary: { "/cache/fold-helper" },
            launch: { executable, arguments in
                calls.record(executable, arguments)
                return readers.make()
            }
        )
        monitor.start()
        let reader = try #require(await readers.first())
        reader.emit(Self.validLine)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(calls.all().first?.1 == ["simctl", "spawn", "U1", "/cache/fold-helper", "watch"])
        // A working guest reader never needs the fallback, so the probe, a
        // process of its own, is never run.
        #expect(asked.value() == 0)
        monitor.stop()
    }

    @Test("a helper that cannot be built gives way to devicectl at once")
    func anUnbuildableHelperFallsBackToDevicectl() async throws {
        let calls = Calls()
        let readers = Readers()
        let monitor = HingeMonitor(
            udid: "U1",
            onAngle: { _ in },
            devicectlAvailable: { true },
            sessionSeconds: 600,
            restartDelay: 60,
            helperBinary: { throw CocoaError(.fileNoSuchFile) },
            launch: { executable, arguments in
                calls.record(executable, arguments)
                return readers.make()
            }
        )
        monitor.start()
        // The restart delay is a minute, so a reader here means the switch did
        // not wait out a backoff.
        _ = try #require(await readers.first())
        #expect(calls.all().first?.1 == [
            "devicectl", "device", "motion", "hinge-angle", "--device", "U1", "--session-timeout", "600"
        ])
        monitor.stop()
    }

    @Test("a guest reader that keeps exiting gives way to devicectl")
    func repeatedGuestExitsFallBackToDevicectl() async {
        let calls = Calls()
        let readers = Readers()
        let monitor = HingeMonitor(
            udid: "U1",
            onAngle: { _ in },
            devicectlAvailable: { true },
            restartDelay: 0.01,
            helperBinary: { "/cache/fold-helper" },
            launch: { executable, arguments in
                calls.record(executable, arguments)
                return readers.make()
            }
        )
        monitor.start()
        for index in 0..<HingeMonitor.guestFailureLimit {
            #expect(await readers.reachesCount(index + 1))
            readers.at(index)?.finish()
        }
        #expect(await readers.reachesCount(HingeMonitor.guestFailureLimit + 1))
        let launched = calls.all().map(\.1.first)
        #expect(launched == Array(repeating: "simctl", count: HingeMonitor.guestFailureLimit) + ["devicectl"])
        monitor.stop()
    }

    @Test("a reading between exits keeps the monitor on the guest reader")
    func aReadingResetsTheFallbackCount() async throws {
        let calls = Calls()
        let readers = Readers()
        let monitor = HingeMonitor(
            udid: "U1",
            onAngle: { _ in },
            devicectlAvailable: { true },
            restartDelay: 0.01,
            helperBinary: { "/cache/fold-helper" },
            launch: { executable, arguments in
                calls.record(executable, arguments)
                return readers.make()
            }
        )
        monitor.start()
        // One short of the limit, a reading, then one short again: never the
        // limit in a row, so the reader that works keeps its place.
        let exits = HingeMonitor.guestFailureLimit - 1
        for index in 0..<(exits * 2) {
            #expect(await readers.reachesCount(index + 1))
            if index == exits {
                readers.at(index)?.emit(Self.validLine)
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            readers.at(index)?.finish()
        }
        #expect(await readers.reachesCount(exits * 2 + 1))
        #expect(calls.all().allSatisfy { $0.1.first == "simctl" })
        monitor.stop()
    }

    @Test("a guest reader that cannot run stays in use without devicectl")
    func noFallbackKeepsRetryingTheGuest() async {
        let calls = Calls()
        let readers = Readers()
        let monitor = HingeMonitor(
            udid: "U1",
            onAngle: { _ in },
            devicectlAvailable: { false },
            restartDelay: 0.01,
            maximumRestartDelay: 0.01,
            helperBinary: { "/cache/fold-helper" },
            launch: { executable, arguments in
                calls.record(executable, arguments)
                return readers.make()
            }
        )
        monitor.start()
        let attempts = HingeMonitor.guestFailureLimit + 1
        for index in 0..<attempts {
            #expect(await readers.reachesCount(index + 1))
            readers.at(index)?.finish()
        }
        #expect(await readers.reachesCount(attempts + 1))
        #expect(calls.all().allSatisfy { $0.1.first == "simctl" })
        monitor.stop()
    }

    @Test("a silent guest reader is not a failure")
    func silenceNeverFallsBack() async throws {
        let asked = Counter()
        let readers = Readers()
        let monitor = HingeMonitor(
            udid: "U1",
            onAngle: { _ in },
            devicectlAvailable: {
                _ = asked.bump()
                return true
            },
            restartDelay: 0.01,
            helperBinary: { "/cache/fold-helper" },
            launch: { _, _ in readers.make() }
        )
        monitor.start()
        // No reading and no exit: a device with no hinge event yet, or an
        // idle hinge. The reader is listening, not broken.
        _ = try #require(await readers.first())
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(readers.count() == 1)
        #expect(asked.value() == 0)
        monitor.stop()
    }

    @Test("a guest reader is not replaced on a timer")
    func theGuestReaderHasNoWindow() async throws {
        let readers = Readers()
        let monitor = HingeMonitor(
            udid: "U",
            onAngle: { _ in },
            devicectlAvailable: { false },
            sessionSeconds: 0,
            restartDelay: 0.01,
            helperBinary: { "/test/fold-helper" },
            launch: { _, _ in readers.make() }
        )
        monitor.start()
        let first = try #require(await readers.first())
        // The window is `devicectl`'s quirk. A zero window would replace a
        // guest reader at once if it applied there too.
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(readers.count() == 1)
        #expect(!first.wasTerminated())
        monitor.stop()
    }
}

/// Angles seen by the monitor's callback, which arrives off the test's task.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var angles: [Double] = []

    func append(_ angle: Double) {
        lock.lock()
        angles.append(angle)
        lock.unlock()
    }

    func values() -> [Double] {
        lock.lock()
        defer { lock.unlock() }
        return angles
    }

    /// Poll until the collected angles match, rather than sleeping a fixed
    /// span and hoping. Returns false if they never do.
    func reaches(_ expected: [Double]) async -> Bool {
        for _ in 0..<200 {
            if values() == expected { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }
}

/// Readers handed out to the monitor, so a test can drive the one it got.
private final class Readers: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [FakeHingeProcess] = []

    func make() -> HingeMonitorProcess {
        let reader = FakeHingeProcess()
        lock.lock()
        made.append(reader)
        lock.unlock()
        return reader
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return made.count
    }

    /// The reader made `index`-th, counting from zero.
    func at(_ index: Int) -> FakeHingeProcess? {
        lock.lock()
        defer { lock.unlock() }
        return made.indices.contains(index) ? made[index] : nil
    }

    func first() async -> FakeHingeProcess? {
        guard await reachesCount(1) else { return nil }
        return firstMade()
    }

    /// Separate from `first()` because `NSLock` is unavailable from an async
    /// context, and the wait above has to be async.
    private func firstMade() -> FakeHingeProcess? {
        lock.lock()
        defer { lock.unlock() }
        return made.first
    }

    func reachesCount(_ target: Int) async -> Bool {
        for _ in 0..<200 {
            if count() >= target { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }
}

/// A reader the test drives: emit text, end the stream, observe termination.
private final class FakeHingeProcess: HingeMonitorProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var output: (@Sendable (Data) -> Void)?
    private var exit: (@Sendable () -> Void)?
    private var terminated = false

    func onOutput(_ handler: @escaping @Sendable (Data) -> Void) {
        lock.lock()
        output = handler
        lock.unlock()
    }

    func onExit(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        exit = handler
        lock.unlock()
    }

    func terminate() {
        lock.lock()
        terminated = true
        lock.unlock()
    }

    func emit(_ text: String) {
        emit(Data(text.utf8))
    }

    /// Emit raw bytes, for a chunk cut somewhere a string cannot express.
    func emit(_ data: Data) {
        lock.lock()
        let handler = output
        lock.unlock()
        handler?(data)
    }

    /// End the stream the way a reader dying unexpectedly does.
    func finish() {
        lock.lock()
        let handler = exit
        lock.unlock()
        handler?()
    }

    func wasTerminated() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminated
    }
}

/// Counts launch attempts.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// Increment and return the new value.
    func bump() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    func value() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// Launches the monitor asked for, as (executable, arguments).
private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(String, [String])] = []

    func record(_ executable: String, _ arguments: [String]) {
        lock.lock()
        calls.append((executable, arguments))
        lock.unlock()
    }

    func first() -> (String, [String])? {
        lock.lock()
        defer { lock.unlock() }
        return calls.first
    }

    func all() -> [(String, [String])] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

/// The environment the hinge reader runs in.
///
/// `LANG` is the difference between a `devicectl` reader that streams and one
/// that is silent for the life of a pane, so it gets its own coverage rather
/// than riding along with the parse.
struct HingeReaderEnvironmentTests {
    @Test
    func aMissingLocaleIsSuppliedSoTheReaderStreams() {
        // launchd starts the daemon without one. Left alone, `devicectl`
        // block-buffers stdout, and this reader never exits to flush it.
        let prepared = HingeMonitor.readerEnvironment(inheriting: ["PATH": "/usr/bin"])
        #expect(prepared["LANG"] == HingeMonitor.readerLocale)
        #expect(prepared["PATH"] == "/usr/bin")
    }

    @Test
    func anOperatorsOwnLocaleIsLeftAlone() {
        let prepared = HingeMonitor.readerEnvironment(
            inheriting: ["LANG": "de_DE.UTF-8"]
        )
        #expect(prepared["LANG"] == "de_DE.UTF-8")
    }

    @Test
    func theSuppliedLocaleIsUTF8() {
        // A non-UTF-8 locale parses fine but drops the degree signs, so the
        // one supplied deliberately is not that.
        #expect(HingeMonitor.readerLocale.hasSuffix("UTF-8"))
    }
}

/// Whether a host has the `devicectl` fallback, from what its `devicectl`
/// says about itself.
struct HingeReaderSourceTests {
    @Test
    func aDevicectlWithTheMotionGroupIsAFallback() {
        let help = "OVERVIEW: Monitor device motion.\n\nSUBCOMMANDS:\n  hinge-angle   Monitor the hinge angle."
        #expect(HingeReaderSource.devicectlHasHingeAngle(helpOutput: help))
    }

    @Test
    func aDevicectlWithoutItIsNot() {
        // What the Xcode 27.1 RC's `devicectl` prints for `device motion
        // --help`: the `device` help, since it has no `motion` group.
        let help = "OVERVIEW: Commands to interact with devices.\n\nSUBCOMMANDS:\n"
            + "  orientation   Control device orientation."
        #expect(!HingeReaderSource.devicectlHasHingeAngle(helpOutput: help))
    }
}

private final class CollectedOrientations: @unchecked Sendable {
    private let lock = NSLock()
    private var orientations: [Orientation] = []

    func append(_ orientation: Orientation) {
        lock.lock()
        orientations.append(orientation)
        lock.unlock()
    }

    func values() -> [Orientation] {
        lock.lock()
        defer { lock.unlock() }
        return orientations
    }

    func reaches(_ expected: [Orientation]) async -> Bool {
        for _ in 0..<200 {
            if values() == expected { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }
}
