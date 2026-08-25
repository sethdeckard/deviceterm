// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import Testing

// TunnelKeepaliveTests: the ref-counted lifecycle of the borrowed
// `devicectl` tunnel keepalive, exercised against a fake spawner so no
// real subprocess (or device) is involved. Pins: spawn-once-per-device,
// ref-count, kill-on-last-release, shutdownAll, and respawn of a dead
// handle.

private final class FakeHandle: KeepaliveHandle, @unchecked Sendable {
    var running = true
    private(set) var interrupts = 0

    var isRunning: Bool { running }

    func interrupt() {
        interrupts += 1
        running = false
    }
}

// All access is serialized through the keepalive's internal queue (the
// spawner runs inside `queue.sync`), so a plain reference recorder is
// safe; `@unchecked Sendable` documents that invariant.
private final class SpawnLog: @unchecked Sendable {
    private(set) var spawnedUDIDs: [String] = []
    private(set) var handles: [FakeHandle] = []

    func spawn(_ udid: String) -> KeepaliveHandle? {
        let handle = FakeHandle()
        spawnedUDIDs.append(udid)
        handles.append(handle)
        return handle
    }
}

@Test("retain spawns once per device; repeat retains ref-count")
func retainRefCounts() {
    let log = SpawnLog()
    let keepalive = TunnelKeepalive(spawner: { log.spawn($0) })
    keepalive.retain(udid: "A")
    keepalive.retain(udid: "A")
    #expect(log.spawnedUDIDs == ["A"])
    #expect(keepalive.heldDeviceCount == 1)
}

@Test("the last release kills the subprocess")
func lastReleaseKills() {
    let log = SpawnLog()
    let keepalive = TunnelKeepalive(spawner: { log.spawn($0) })
    keepalive.retain(udid: "A")
    keepalive.retain(udid: "A")
    keepalive.release(udid: "A")
    #expect(keepalive.heldDeviceCount == 1)
    #expect(log.handles[0].interrupts == 0)
    keepalive.release(udid: "A")
    #expect(keepalive.heldDeviceCount == 0)
    #expect(log.handles[0].interrupts == 1)
}

@Test("release with no matching retain is a no-op")
func releaseWithoutRetain() {
    let log = SpawnLog()
    let keepalive = TunnelKeepalive(spawner: { log.spawn($0) })
    keepalive.release(udid: "ghost")
    #expect(keepalive.heldDeviceCount == 0)
    #expect(log.spawnedUDIDs.isEmpty)
}

@Test("shutdownAll kills every keepalive")
func shutdownAllKillsEverything() {
    let log = SpawnLog()
    let keepalive = TunnelKeepalive(spawner: { log.spawn($0) })
    keepalive.retain(udid: "A")
    keepalive.retain(udid: "B")
    #expect(keepalive.heldDeviceCount == 2)
    keepalive.shutdownAll()
    #expect(keepalive.heldDeviceCount == 0)
    #expect(log.handles.allSatisfy { $0.interrupts == 1 })
}

@Test("a dead handle is respawned on the next retain")
func deadHandleRespawns() {
    let log = SpawnLog()
    let keepalive = TunnelKeepalive(spawner: { log.spawn($0) })
    keepalive.retain(udid: "A")
    log.handles[0].running = false  // the devicectl process exited on its own
    keepalive.retain(udid: "A")
    #expect(log.spawnedUDIDs == ["A", "A"])
    #expect(keepalive.heldDeviceCount == 1)
}
