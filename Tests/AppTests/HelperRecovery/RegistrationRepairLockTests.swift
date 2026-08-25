// SPDX-License-Identifier: GPL-3.0-or-later
//
// RegistrationRepairLockTests: the cross-process exclusion around a registration
// repair.
//
// `flock` is used here for one property above all: the kernel releases it when
// the holder exits, however it exits. That is what makes it a barrier a marker
// file cannot be. A marker can say a repair was interrupted; it cannot say one
// is running right now without the reader sampling liveness, and every such
// sample has a race after it.
//
// The out-of-process case is exercised with a real second process, because
// `flock` is per open file description: two acquisitions inside one process can
// behave differently from two processes, so an in-process test would prove the
// wrong thing.

@testable import App
import Foundation
import Testing

@MainActor
struct RegistrationRepairLockTests {
    private func makeLockPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("deviceterm-lock-\(UUID().uuidString)")
            .appendingPathComponent("registration-repair.lock")
            .path
    }

    /// Holds the lock in a separate process until the returned process is
    /// terminated, so contention is genuinely cross-process.
    private func holdLockInAnotherProcess(at path: String) throws -> Process {
        // The helper opens the file directly, so its directory has to exist
        // before it runs; only `tryAcquire` creates that on the Swift side.
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let script = """
            $| = 1;
            open(my $fh, '+>', $ARGV[0]) or die "open: $!";
            flock($fh, 2) or die "flock: $!";
            print "locked\\n";
            sleep 60;
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", script, path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        // Wait for it to announce the lock is held. The helper prints only after
        // `flock` returns, so a NONEMPTY byte is the proof; anything else means
        // it died instead, and the caller would be racing a lock nobody holds.
        let announced = try pipe.fileHandleForReading.read(upToCount: 1)
        guard let announced, !announced.isEmpty else {
            Issue.record("the lock helper exited before taking the lock")
            return process
        }
        return process
    }

    @Test
    func anUncontendedLockIsAcquired() throws {
        let path = makeLockPath()
        var handle = try RegistrationRepairLock.tryAcquire(at: path)
        #expect(handle != nil)
        handle = nil
    }

    @Test
    func acquiringCreatesTheParentDirectory() throws {
        let path = makeLockPath()
        let handle = try RegistrationRepairLock.tryAcquire(at: path)
        #expect(FileManager.default.fileExists(atPath: path))
        withExtendedLifetime(handle) {}
    }

    @Test
    func aLockHeldByAnotherProcessIsReportedAsContendedNotAsAnError() throws {
        // Contention is an ordinary outcome the caller waits out. An error means
        // the lock file itself is unusable, which is a different problem and
        // must not be mistaken for it.
        let path = makeLockPath()
        let holder = try holdLockInAnotherProcess(at: path)
        defer { holder.terminate() }

        #expect(try RegistrationRepairLock.tryAcquire(at: path) == nil)
    }

    @Test
    func theKernelReleasesTheLockWhenTheHolderDies() throws {
        // The property that removes staleness entirely: no owner pid to record,
        // no liveness check to get wrong, nothing to clean up after a crash.
        let path = makeLockPath()
        let holder = try holdLockInAnotherProcess(at: path)
        #expect(try RegistrationRepairLock.tryAcquire(at: path) == nil)

        holder.terminate()
        holder.waitUntilExit()

        var handle = try RegistrationRepairLock.tryAcquire(at: path)
        #expect(handle != nil)
        handle = nil
    }

    @Test
    func droppingTheLastReferenceReleasesTheLock() throws {
        // Release is ARC, deliberately: the handle is shared between a launch
        // and a background repair that outlives it, and an eager release by
        // either would close the descriptor out from under the other.
        let path = makeLockPath()
        var first = try RegistrationRepairLock.tryAcquire(at: path)
        #expect(first != nil)
        first = nil

        var second = try RegistrationRepairLock.tryAcquire(at: path)
        #expect(second != nil)
        second = nil
    }

    @Test
    func handingTheStartupLockToARepairKeepsItHeldWithoutReacquiring() throws {
        // The property the startup critical section depends on: the launch lets
        // go while a background repair keeps the same handle, and the lock stays
        // held until that repair is done. The repair reuses the handle because a
        // second acquisition would contend with the startup's own descriptor.
        let path = makeLockPath()
        var launchHeld = try RegistrationRepairLock.tryAcquire(at: path)
        var repairHeld = launchHeld

        #expect(try RegistrationRepairLock.tryAcquire(at: path) == nil)

        launchHeld = nil
        #expect(repairHeld != nil)
        #expect(try RegistrationRepairLock.tryAcquire(at: path) == nil)

        repairHeld = nil
        let reacquired = try RegistrationRepairLock.tryAcquire(at: path)
        #expect(reacquired != nil)
    }

    @Test
    func anUnusableLockPathThrowsRatherThanReportingContention() {
        // `/dev/null` cannot host a directory, so the parent create fails.
        // Reporting that as contention would make a caller wait out a repair
        // that is not happening.
        #expect(throws: (any Error).self) {
            _ = try RegistrationRepairLock.tryAcquire(
                at: "/dev/null/deviceterm/registration-repair.lock"
            )
        }
    }
}
