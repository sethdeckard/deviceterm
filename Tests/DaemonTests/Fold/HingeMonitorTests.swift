// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import Foundation
import Testing

/// `HingeMonitor`'s process handling, driven through a fake reader so no
/// `devicectl` is spawned.
///
/// The behaviours here are the ones the measured contract forces: the reader
/// never exits on its own, so an exit is unexpected and a monitor still wanted
/// replaces it; the monitoring window ends without an exit or any output, so it
/// has to be timed; and output arrives in chunks that ignore line boundaries,
/// so a reading split across two reads still has to parse.
struct HingeMonitorTests {
    private static let validLine =
        "• +1.000s : Angle: 42.0°  Mech: 42.0°  Velocity:+0.0°/s  AngleValid:Y  Range:0-180°\n"

    @Test("reports every angle in the stream")
    func reportsAngles() async throws {
        let collected = Collected()
        let readers = Readers()
        let monitor = HingeMonitor(
            udid: "U",
            onAngle: { collected.append($0) },
            restartDelay: .milliseconds(10),
            launch: { _, _ in readers.make() }
        )
        monitor.start()
        let reader = try #require(await readers.first())
        reader.emit(Self.validLine)
        #expect(await collected.reaches([42.0]))
        monitor.stop()
    }

    @Test("a reading split across two reads still parses")
    func reassemblesASplitLine() async throws {
        let collected = Collected()
        let readers = Readers()
        let monitor = HingeMonitor(
            udid: "U",
            onAngle: { collected.append($0) },
            restartDelay: .milliseconds(10),
            launch: { _, _ in readers.make() }
        )
        monitor.start()
        let reader = try #require(await readers.first())
        // The pipe splits wherever it likes. Halving mid-number is the case
        // that would otherwise parse as two unusable fragments.
        let line = Self.validLine
        let cut = line.index(line.startIndex, offsetBy: 22)
        reader.emit(String(line[line.startIndex..<cut]))
        reader.emit(String(line[cut...]))
        #expect(await collected.reaches([42.0]))
        monitor.stop()
    }

    @Test("a chunk cut inside a multi-byte character still parses")
    func reassemblesASplitMultiByteCharacter() async throws {
        let collected = Collected()
        let readers = Readers()
        let monitor = HingeMonitor(
            udid: "U",
            onAngle: { collected.append($0) },
            restartDelay: .milliseconds(10),
            launch: { _, _ in readers.make() }
        )
        monitor.start()
        let reader = try #require(await readers.first())
        // `°` is two bytes and `•` is three. Cutting between the bytes of one
        // is what a decode-per-chunk drops, taking the reading with it.
        let bytes = Data(Self.validLine.utf8)
        let degreeSign = Data("°".utf8)
        let inside = try #require(bytes.firstIndex(of: degreeSign[degreeSign.startIndex]))
        reader.emit(bytes[bytes.startIndex...inside])
        reader.emit(bytes[bytes.index(after: inside)...])
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
            restartDelay: .milliseconds(10),
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
            restartDelay: .milliseconds(10),
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

    @Test("the reader is replaced when its window elapses")
    func replacesTheReaderWhenTheWindowEnds() async throws {
        let readers = Readers()
        let monitor = HingeMonitor(
            udid: "U",
            onAngle: { _ in },
            sessionSeconds: 0,
            restartDelay: .milliseconds(10),
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

    @Test("a stopped monitor never spawns again")
    func doesNotRestartAfterStop() async throws {
        let readers = Readers()
        let monitor = HingeMonitor(
            udid: "U",
            onAngle: { _ in },
            restartDelay: .milliseconds(10),
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
            restartDelay: .milliseconds(10),
            launch: { _, _ in readers.make() }
        )
        monitor.start()
        monitor.start()
        _ = try #require(await readers.first())
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(readers.count() == 1)
        monitor.stop()
    }

    @Test("a launch that fails is retried")
    func retriesAFailedLaunch() async {
        let attempts = Counter()
        let readers = Readers()
        let monitor = HingeMonitor(
            udid: "U",
            onAngle: { _ in },
            restartDelay: .milliseconds(10),
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

    /// End the stream the way a reader dying unexpectedly does. A session
    /// window elapsing is not this: it leaves the process running.
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

/// The environment the hinge reader runs in.
///
/// `LANG` is the difference between a reader that streams and one that is
/// silent for the life of a pane, so it gets its own coverage rather than
/// riding along with the parse.
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
