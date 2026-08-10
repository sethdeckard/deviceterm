// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import Foundation
import Testing

// SubscriptionLifecycle: the late-bound teardown box every XPC pane
// subscription carries. These pin the ordering the transport depends on:
// a cause queued before its target installs is applied on install; orphan
// dominates drain; the producer cleanup fires exactly once no matter how
// many paths reference it.

/// Records which pool teardown cause was applied, and how many times the
/// producer cleanup ran. `@unchecked Sendable`: each test drives the
/// lifecycle with one awaited call at a time and reads only after those
/// awaits return, so every mutation happens-before the next access. There
/// is no concurrent access to synchronize (the teardown closures aren't
/// themselves actor-isolated).
private final class LifecycleProbe: @unchecked Sendable {
    var appliedCauses: [SubscriptionLifecycle.Cause] = []
    var cleanupCount = 0
}

@Test("a drain queued before the pool teardown installs is applied on install")
func drainQueuedBeforeInstallAppliesOnInstall() async {
    let probe = LifecycleProbe()
    let lifecycle = SubscriptionLifecycle()

    await lifecycle.fire(.drain)
    #expect(await lifecycle.hasTerminalCause())
    #expect(probe.appliedCauses.isEmpty)

    await lifecycle.installPoolTeardown { cause in probe.appliedCauses.append(cause) }
    #expect(probe.appliedCauses == [.drain])
}

@Test("orphan dominates a prior drain")
func orphanDominatesDrain() async {
    let probe = LifecycleProbe()
    let lifecycle = SubscriptionLifecycle()
    await lifecycle.installPoolTeardown { cause in probe.appliedCauses.append(cause) }

    await lifecycle.fire(.drain)
    await lifecycle.fire(.orphan)
    // Drain applies first (immediately, teardown already installed), then
    // orphan upgrades it; a later drain never downgrades.
    await lifecycle.fire(.drain)
    #expect(probe.appliedCauses == [.drain, .orphan])
}

@Test("a producer cleanup installed after a cause fired runs immediately, once")
func producerCleanupInstalledAfterCauseRunsOnce() async {
    let probe = LifecycleProbe()
    let lifecycle = SubscriptionLifecycle()

    await lifecycle.fire(.drain)
    #expect(probe.cleanupCount == 0)
    await lifecycle.installProducerCleanup { probe.cleanupCount += 1 }
    #expect(probe.cleanupCount == 1)

    // A second cause doesn't re-run the cleanup.
    await lifecycle.fire(.orphan)
    #expect(probe.cleanupCount == 1)
}

@Test("the producer cleanup fires exactly once across every path")
func producerCleanupFiresExactlyOnce() async {
    let probe = LifecycleProbe()
    // FireOnce is the wrapper the subscribe handler shares between the
    // local defer, onCancel, and the lifecycle.
    let cleanup = FireOnce { probe.cleanupCount += 1 }
    let lifecycle = SubscriptionLifecycle()
    await lifecycle.installProducerCleanup { cleanup() }

    // The lifecycle fires it, then onCancel and the defer both fire the
    // same closure, still one net cleanup.
    await lifecycle.fire(.drain)
    cleanup()
    cleanup()
    #expect(probe.cleanupCount == 1)
}
