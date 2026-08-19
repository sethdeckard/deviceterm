// SPDX-License-Identifier: GPL-3.0-or-later
//
// RegistrationRepairLock: cross-process exclusion around a launchd registration
// repair.
//
// The helper is a per-user singleton, so two copies of DeviceTerm can try to
// repair its registration at once, and a launch can arrive while another copy is
// mid-repair. Between the unregister and the register the helper is registered
// nowhere, so a second process that registers or connects in that window is
// acting on a half-torn-down registration.
//
// A marker file cannot provide this. A marker records that a repair was
// interrupted; it cannot say "one is happening right now" without the reader
// sampling some liveness signal, and every such sample is a guess with a race
// after it. This is `flock(2)` instead, which the kernel arbitrates.
//
// The property that makes it the right tool: the lock is tied to an open file
// descriptor, so the kernel releases it when the process exits, however it
// exits. There is no stale lock to detect, no owner pid to record, and no
// liveness check to get wrong. A process killed mid-repair drops the lock and
// leaves its marker, which is exactly the pair the next launch needs.
//
// Acquisition is non-blocking. Callers poll against their own deadline rather
// than blocking a launch indefinitely on another process's repair.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

@MainActor
enum RegistrationRepairLock {
    /// Proof that the repair lock is held, and the thing that releases it.
    ///
    /// Passed into the repair rather than acquired inside it, so a repair cannot
    /// be started without the lock: the type system carries the requirement
    /// instead of a comment asking callers to remember.
    ///
    /// **The lock releases on `deinit` and there is deliberately no way to
    /// release it early.** The handle is shared: a launch holds it across
    /// registration and the version handshake, and a repair that outran the
    /// launch's patience holds the same one while it keeps running in the
    /// background. An eager release by either would close the descriptor out
    /// from under the other and drop the exclusion while a teardown was still in
    /// flight, which is the exact state the lock exists to rule out.
    ///
    /// So the lifetime is the union of its owners, which is what ARC already
    /// computes. Callers drop their reference; the last one out closes the
    /// descriptor. Holding it a moment longer than needed is the safe direction,
    /// and process exit closes the descriptor regardless.
    @MainActor
    final class Handle {
        private let descriptor: Int32

        init(descriptor: Int32) {
            self.descriptor = descriptor
        }

        deinit {
            // Closing the descriptor releases the flock; the explicit unlock is
            // for clarity about what the close is doing.
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }

    /// Try to take the lock without blocking. Returns nil when another process
    /// holds the startup/repair lock, which covers an ordinary launch holding it
    /// across registration and the handshake as well as an in-flight repair.
    ///
    /// Throws only when the lock file itself cannot be opened, which is a
    /// different problem from contention and must not be mistaken for it.
    static func tryAcquire(at path: String) throws -> Handle? {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = open(path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else {
            throw RegistrationRepairLockError.cannotOpen(String(cString: strerror(errno)))
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let held = errno == EWOULDBLOCK
            close(descriptor)
            if held { return nil }
            throw RegistrationRepairLockError.cannotLock(String(cString: strerror(errno)))
        }
        return Handle(descriptor: descriptor)
    }
}

enum RegistrationRepairLockError: Error, CustomStringConvertible {
    case cannotOpen(String)
    case cannotLock(String)

    var description: String {
        switch self {
        case let .cannotOpen(reason):
            return "could not open the repair lock: \(reason)"

        case let .cannotLock(reason):
            return "could not take the repair lock: \(reason)"
        }
    }
}
