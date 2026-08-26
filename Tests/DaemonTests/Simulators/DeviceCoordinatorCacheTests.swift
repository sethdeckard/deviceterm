// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
@testable import Daemon
import Dispatch
import Foundation
import Testing

// DeviceCoordinator's short-lived CoreSimulator device snapshot cache.

// These tests use empty device sets because CSBDeviceInfo intentionally has no
// fixture initializer. The cache decisions depend on read results, timing, and
// invalidation generation rather than the contents of a successful snapshot.

private let snapshotTTL: UInt64 = 2_000_000_000

/// Synchronous test state used by the injected synchronous reader and clock.
/// `@unchecked Sendable` is sound because the private serial queue protects
/// every access to the mutable fields.
private final class DeviceReadFixture: @unchecked Sendable {
    private let stateQueue = DispatchQueue(label: "com.deviceterm.tests.device-cache-state")
    private var clockNanoseconds: UInt64 = 0
    private var readCount = 0
    private var scriptedResults: [CoreSimulatorDeviceReadResult]

    var now: UInt64 { stateQueue.sync { clockNanoseconds } }
    var count: Int { stateQueue.sync { readCount } }
    var hasNoReads: Bool { stateQueue.sync { readCount == 0 } }

    init(results: [CoreSimulatorDeviceReadResult] = [.success([])]) {
        self.scriptedResults = results
    }

    func advance(by nanoseconds: UInt64) {
        stateQueue.sync { clockNanoseconds += nanoseconds }
    }

    func read() throws -> [CSBDeviceInfo] {
        let result = stateQueue.sync { () -> CoreSimulatorDeviceReadResult in
            readCount += 1
            let index = min(readCount - 1, scriptedResults.count - 1)
            return scriptedResults[index]
        }
        return try result.get()
    }
}

/// Proves the injected bridge closure runs on the reader's dedicated queue.
private final class DeviceReaderQueueProbe: @unchecked Sendable {
    private let key = DispatchSpecificKey<Bool>()
    private let stateQueue = DispatchQueue(label: "com.deviceterm.tests.device-cache-queue-probe")
    private var observations: [Bool] = []

    var allReadsUsedReaderQueue: Bool {
        stateQueue.sync { !observations.isEmpty && observations.allSatisfy(\.self) }
    }

    func install(on queue: DispatchQueue) {
        queue.setSpecific(key: key, value: true)
    }

    func observeCurrentQueue() {
        let isReaderQueue = DispatchQueue.getSpecific(key: key) == true
        stateQueue.sync { observations.append(isReaderQueue) }
    }
}

/// Deterministic replacement for the production sleep. Each `fire()` releases
/// the one active deadline waiter; cancelling that waiter makes `next()` return
/// nil, so completed reads retire their timer without leaving a test task.
private final class DeviceReadDeadlineFixture: @unchecked Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
    }

    func sleep(nanoseconds _: UInt64) async throws {
        var iterator = stream.makeAsyncIterator()
        guard await iterator.next() != nil else { throw CancellationError() }
    }

    func fire() {
        continuation.yield(())
    }
}

private func makeCoordinator(
    fixture: DeviceReadFixture,
    readerQueue: DispatchQueue = DispatchQueue(
        label: "com.deviceterm.tests.device-cache-reader",
        qos: .default
    ),
    deadline: DeviceReadDeadlineFixture? = nil,
    beforeRead: (@Sendable () -> Void)? = nil,
    afterRead: (@Sendable () -> Void)? = nil
) -> DeviceCoordinator {
    DeviceCoordinator(
        deviceSnapshotTTLNanoseconds: snapshotTTL,
        deviceSnapshotClock: { fixture.now },
        deviceSnapshotSleep: { nanoseconds in
            if let deadline {
                try await deadline.sleep(nanoseconds: nanoseconds)
            } else {
                try await Task.sleep(nanoseconds: nanoseconds)
            }
        },
        deviceReaderQueue: readerQueue,
        readDevices: {
            beforeRead?()
            let devices = try fixture.read()
            afterRead?()
            return devices
        }
    )
}

private func waitOffExecutor(for semaphore: DispatchSemaphore) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .default).async {
            semaphore.wait()
            continuation.resume()
        }
    }
}

private func awaitRecoveredRead(from coordinator: DeviceCoordinator) async -> [CSBDeviceInfo]? {
    for _ in 0..<1_000 {
        if let devices = try? await coordinator.listAll() {
            return devices
        }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return nil
}

@Test
func deviceSnapshotIsSharedAcrossListingAndBootChecks() async throws {
    let fixture = DeviceReadFixture()
    let readerQueue = DispatchQueue(
        label: "com.deviceterm.tests.device-cache-shared-reader",
        qos: .default
    )
    let queueProbe = DeviceReaderQueueProbe()
    queueProbe.install(on: readerQueue)
    let coordinator = makeCoordinator(
        fixture: fixture,
        readerQueue: readerQueue,
        beforeRead: { queueProbe.observeCurrentQueue() }
    )

    _ = try await coordinator.listAll()
    #expect(await !coordinator.isBooted(udid: UUID().uuidString))
    _ = try await coordinator.listAll()

    #expect(fixture.count == 1)
    #expect(queueProbe.allReadsUsedReaderQueue)
}

@Test
func deviceSnapshotRefreshesAtTTLBoundary() async throws {
    let fixture = DeviceReadFixture()
    let coordinator = makeCoordinator(fixture: fixture)

    _ = try await coordinator.listAll()
    fixture.advance(by: snapshotTTL - 1)
    _ = try await coordinator.listAll()
    #expect(fixture.count == 1)

    fixture.advance(by: 1)
    _ = try await coordinator.listAll()
    #expect(fixture.count == 2)
}

@Test
func failedDeviceSnapshotIsCachedWithTheSameTTL() async {
    let fixture = DeviceReadFixture(results: [
        .failure(CoreSimulatorDeviceReadFailure(message: "fixture unavailable"))
    ])
    let coordinator = makeCoordinator(fixture: fixture)

    await #expect(throws: DeviceError.listFailed(message: "fixture unavailable")) {
        try await coordinator.listAll()
    }
    #expect(await !coordinator.isBooted(udid: UUID().uuidString))
    await #expect(throws: DeviceError.listFailed(message: "fixture unavailable")) {
        try await coordinator.listAll()
    }

    #expect(fixture.count == 1)
}

@Test
func failedRefreshReplacesExpiredSuccessfulSnapshot() async throws {
    let fixture = DeviceReadFixture(results: [
        .success([]),
        .failure(CoreSimulatorDeviceReadFailure(message: "fixture unavailable"))
    ])
    let coordinator = makeCoordinator(fixture: fixture)

    _ = try await coordinator.listAll()
    fixture.advance(by: snapshotTTL)
    await #expect(throws: DeviceError.listFailed(message: "fixture unavailable")) {
        try await coordinator.listAll()
    }
    await #expect(throws: DeviceError.listFailed(message: "fixture unavailable")) {
        try await coordinator.listAll()
    }

    #expect(fixture.count == 2)
}

@Test
func concurrentDeviceSnapshotMissesShareOneRead() async throws {
    let fixture = DeviceReadFixture()
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let coordinator = makeCoordinator(fixture: fixture) {
        entered.signal()
        release.wait()
    }

    let first = Task { try await coordinator.listAll() }
    await waitOffExecutor(for: entered)
    let second = Task { try await coordinator.listAll() }
    for _ in 0..<10 { await Task.yield() }
    #expect(fixture.hasNoReads)

    release.signal()
    _ = try await first.value
    _ = try await second.value
    #expect(fixture.count == 1)
}

@Test
func blockedDeviceSnapshotTimesOutAllWaitersAndOpensCircuit() async {
    let fixture = DeviceReadFixture()
    let deadline = DeviceReadDeadlineFixture()
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let coordinator = makeCoordinator(fixture: fixture, deadline: deadline) {
        entered.signal()
        release.wait()
    }

    let first = Task { try await coordinator.listAll() }
    await waitOffExecutor(for: entered)
    let second = Task { try await coordinator.listAll() }
    for _ in 0..<10 { await Task.yield() }
    deadline.fire()

    await #expect(throws: DeviceError.listTimedOut) { try await first.value }
    await #expect(throws: DeviceError.listTimedOut) { try await second.value }
    await #expect(throws: DeviceError.listTimedOut) { try await coordinator.listAll() }
    #expect(fixture.hasNoReads)

    release.signal()
    #expect(await awaitRecoveredRead(from: coordinator) != nil)
    #expect(fixture.count == 1)
}

@Test
func ownershipRestorePropagatesDeviceSnapshotTimeout() async {
    let fixture = DeviceReadFixture()
    let deadline = DeviceReadDeadlineFixture()
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let coordinator = makeCoordinator(fixture: fixture, deadline: deadline) {
        entered.signal()
        release.wait()
    }
    let claims = [UUID().uuidString.lowercased(): UUID?.none]

    let restore = Task { try await coordinator.restoreOwnership(claims) }
    await waitOffExecutor(for: entered)
    deadline.fire()

    await #expect(throws: DeviceError.listTimedOut) { try await restore.value }
    release.signal()
    #expect(await awaitRecoveredRead(from: coordinator) != nil)
}

@Test
func invalidationCannotQueueBehindTimedOutDeviceRead() async {
    let fixture = DeviceReadFixture()
    let deadline = DeviceReadDeadlineFixture()
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let completed = DispatchSemaphore(value: 0)
    let coordinator = makeCoordinator(
        fixture: fixture,
        deadline: deadline,
        beforeRead: {
            if fixture.hasNoReads {
                entered.signal()
                release.wait()
            }
        },
        afterRead: { completed.signal() }
    )

    let first = Task { try await coordinator.listAll() }
    await waitOffExecutor(for: entered)
    deadline.fire()
    await #expect(throws: DeviceError.listTimedOut) { try await first.value }

    await coordinator.noteExternalBoot(udid: UUID().uuidString)
    await #expect(throws: DeviceError.listTimedOut) { try await coordinator.listAll() }
    release.signal()
    await waitOffExecutor(for: completed)
    for _ in 0..<10 { await Task.yield() }
    #expect(fixture.count == 1)

    #expect(await awaitRecoveredRead(from: coordinator) != nil)
    #expect(fixture.count == 2)
}

@Test
func invalidatedWaitersRetryInsteadOfReturningAnOldRead() async {
    let fixture = DeviceReadFixture(results: [
        .success([]),
        .failure(CoreSimulatorDeviceReadFailure(message: "fixture unavailable"))
    ])
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let coordinator = makeCoordinator(fixture: fixture) {
        if fixture.hasNoReads {
            entered.signal()
            release.wait()
        }
    }

    let oldGeneration = Task { try await coordinator.listAll() }
    await waitOffExecutor(for: entered)
    await coordinator.noteExternalBoot(udid: UUID().uuidString)
    let currentGeneration = Task { try await coordinator.listAll() }
    release.signal()

    await #expect(throws: DeviceError.listFailed(message: "fixture unavailable")) {
        try await oldGeneration.value
    }
    await #expect(throws: DeviceError.listFailed(message: "fixture unavailable")) {
        try await currentGeneration.value
    }
    await #expect(throws: DeviceError.listFailed(message: "fixture unavailable")) {
        try await coordinator.listAll()
    }
    #expect(fixture.count == 2)
}

@Test
func emptyOwnedListDoesNotReadCoreSimulator() async throws {
    let fixture = DeviceReadFixture()
    let coordinator = makeCoordinator(fixture: fixture)

    let devices = try await coordinator.listOwned()

    #expect(devices.isEmpty)
    #expect(fixture.hasNoReads)
}

@Test
func shimOwnershipTransitionsInvalidateDeviceSnapshot() async throws {
    let fixture = DeviceReadFixture()
    let coordinator = makeCoordinator(fixture: fixture)
    let udid = UUID().uuidString

    _ = try await coordinator.listAll()
    try await coordinator.recordOwnership(udid: udid, sessionId: UUID())
    _ = try await coordinator.listAll()
    await coordinator.releaseOwnership(udid: udid)
    _ = try await coordinator.listAll()

    #expect(fixture.count == 3)
}

@Test
func externalTransitionsInvalidateDeviceSnapshot() async throws {
    let fixture = DeviceReadFixture()
    let coordinator = makeCoordinator(fixture: fixture)
    let udid = UUID().uuidString

    _ = try await coordinator.listAll()
    await coordinator.noteExternalBoot(udid: udid)
    _ = try await coordinator.listAll()
    await coordinator.noteExternalShutdown(udid: udid)
    _ = try await coordinator.listAll()

    #expect(fixture.count == 3)
}
