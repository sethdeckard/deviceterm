// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Foundation
import Testing

/// The marker recording that a registration repair
/// was started and did not finish.
///
/// The properties under test are ORDERING and FAIL-CLOSED behaviour, which is why
/// these assert sequence and error propagation rather than end state. A marker
/// written after the teardown begins would be useless, and a lookup that answers
/// "nothing to do" on an error it could not complete is the one reading that
/// skips the reconciliation.
///
/// Concurrency is deliberately absent here. The store answers one question, "was
/// a repair started and not finished". In production the callers hold
/// `RegistrationRepairLock` around these calls; these tests do not, because what
/// they exercise is the marker rather than the exclusion. Exclusion is tested in
/// `RegistrationRepairLockTests`.
@MainActor
struct RegistrationRepairStoreTests {
    /// A store pointed at a fresh temporary path, plus that path.
    private func makeStore() -> (store: RegistrationRepairStore, path: String) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("deviceterm-repair-\(UUID().uuidString)")
            .appendingPathComponent("registration-repair")
            .path
        return (RegistrationRepairStore(path: path), path)
    }

    @Test
    func aFreshStoreReportsNoRepairUnderway() throws {
        let (store, _) = makeStore()
        #expect(try !store.isRepairUnderway())
    }

    @Test
    func markingCreatesTheMarkerAndItsParentDirectory() throws {
        let (store, path) = makeStore()
        try store.markRepairUnderway()
        #expect(try store.isRepairUnderway())
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test
    func clearingRemovesTheMarker() throws {
        let (store, _) = makeStore()
        try store.markRepairUnderway()
        try store.clearRepairUnderway()
        #expect(try !store.isRepairUnderway())
    }

    @Test
    func clearingIsIdempotentWhenNoMarkerExists() throws {
        let (store, _) = makeStore()
        try store.clearRepairUnderway()
        #expect(try !store.isRepairUnderway())
    }

    @Test
    func markingIsIdempotent() throws {
        let (store, _) = makeStore()
        try store.markRepairUnderway()
        try store.markRepairUnderway()
        #expect(try store.isRepairUnderway())
        try store.clearRepairUnderway()
        #expect(try !store.isRepairUnderway())
    }

    @Test
    func aSecondStoreOverTheSamePathSeesTheMarker() throws {
        // The marker is the file, not in-memory state: a later launch is a
        // different process reading the same path.
        let (store, path) = makeStore()
        try store.markRepairUnderway()
        #expect(try RegistrationRepairStore(path: path).isRepairUnderway())
    }

    @Test
    func theLockLivesBesideTheMarker() {
        // The pair moves together, so pointing a store at a temporary location
        // relocates its exclusion too.
        let (store, path) = makeStore()
        #expect(store.lockPath == path + ".lock")
    }

    @Test
    func anUnwritableLocationReportsRatherThanSwallowing() {
        // The disqualifying property of the cache-backed bookkeeping this
        // deliberately is not: a swallowed write would let the teardown proceed
        // with no marker behind it, which is the one failure the ordering exists
        // to prevent. `/dev/null` cannot host a directory, so `createDirectory`
        // fails here.
        let store = RegistrationRepairStore(path: "/dev/null/deviceterm/registration-repair")
        #expect(throws: (any Error).self) {
            try store.markRepairUnderway()
        }
    }

    @Test
    func inspectingAnUnreachableLocationThrowsRatherThanAnsweringAbsent() {
        // Absent is the answer that SKIPS reconciliation, so a lookup that could
        // not be completed must not produce it.
        let store = RegistrationRepairStore(path: "/dev/null/deviceterm/registration-repair")
        #expect(throws: (any Error).self) {
            _ = try store.isRepairUnderway()
        }
    }

    @Test
    func theStandardStoreLivesInApplicationSupportNotTheCache() throws {
        // Application Support is durable; the XDG cache directory is purgeable
        // by design and is where the disposable welcome bookkeeping lives.
        //
        // There is deliberately no fallback path: a shared location would be
        // neither per-user nor beside the app's other durable state, so a marker
        // written there would not be the guarantee it looks like.
        let store = try RegistrationRepairStore.standard()
        #expect(store.markerPathForTesting.contains("Application Support"))
        #expect(store.markerPathForTesting.hasSuffix("deviceterm/registration-repair"))
        #expect(!store.markerPathForTesting.hasPrefix("/tmp"))
    }
}
