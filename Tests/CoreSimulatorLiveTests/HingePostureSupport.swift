// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import Foundation
import Testing

// Restoring a shared foldable's posture around a test. The device outlives the
// test that moved it, so every track and every test after this one inherits
// whatever posture it was left in.

/// Run `body`, then set the hinge to `restored` however `body` ended.
///
/// It sets an angle rather than restoring the one from before: nothing reads
/// the prior angle, and the tracks that use this start from a known posture.
///
/// Deliberately not a `defer`: `defer` cannot await, so cleanup started there
/// runs unstructured and the serialized runner can begin the next test while
/// the simulator is still moving.
///
/// The restore runs in an **unstructured** `Task`, because an inline
/// `Task.sleep` throws the instant its task is cancelled, so a torn-down run
/// would reach the restore and then skip it. Such a task does not inherit the
/// caller's cancellation. It is awaited because the device is shared: nothing
/// after this may start while the hinge is still moving.
///
/// A restore that fails is recorded rather than dropped, and never replaces the
/// original failure.
func withHingeRestored<T>(
    _ backend: any DeviceBackend,
    to restored: Double = 0,
    settling: UInt64 = 3_000_000_000,
    _ body: () async throws -> T
) async throws -> T {
    let outcome: Result<T, any Error>
    do {
        outcome = .success(try await body())
    } catch {
        outcome = .failure(error)
    }
    await Task {
        do {
            try await backend.fold(
                toDegrees: restored,
                generation: backend.currentInputGeneration()
            )
            try await Task.sleep(nanoseconds: settling)
        } catch {
            Issue.record("the hinge was left off \(restored) for the tests after this one: \(error)")
        }
    }.value
    return try outcome.get()
}

/// Run `body` with the device unfolded, and set the hinge to 0 afterwards.
///
/// The unfold sits inside the protected region on purpose: a `Task.sleep`
/// throws the instant its task is cancelled, so a wait left outside would hand
/// a torn-down run back with the hinge still open.
func withDeviceUnfolded<T>(
    _ backend: any DeviceBackend,
    settling: UInt64 = 3_000_000_000,
    _ body: () async throws -> T
) async throws -> T {
    try await withHingeRestored(backend, settling: settling) {
        try await backend.fold(toDegrees: 180, generation: backend.currentInputGeneration())
        try await Task.sleep(nanoseconds: settling)
        return try await body()
    }
}
