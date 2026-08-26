// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension Process: KeepaliveHandle {}

/// Holds the CoreDevice RSD tunnel up for a mirrored
/// physical device by *borrowing Apple's own `devicectl`*, so deviceterm
/// mirrors without Device Hub / Xcode open.
///
/// The OS (`remoted`) only keeps a device's `utun` up while a trusted
/// client holds a CoreDevice session. `devicectl device notification
/// observe` is exactly that: a benign, blocking subprocess that parks a
/// session observing a Darwin notification (one that never fires). While
/// it lives the tunnel stays up; SIGINT it and the tunnel drops. Apple's
/// signed binary makes the privileged ask, so the daemon stays user-scope
/// with no entitlement and no helper. (Measured: tunnel up ~0.8s after
/// spawn; the OS lingers it ~10s after the process exits.)
///
/// One keepalive per device, **ref-counted** so several panes can mirror
/// the same device and the tunnel drops only when the last detaches. The
/// spawner is injectable so the ref-count / kill logic is unit-tested
/// without a real device.
///
/// `Process` is not `Sendable`, so state lives behind a serial queue in an
/// `@unchecked Sendable` wrapper rather than an actor, which lets the
/// daemon's *synchronous* `applicationWillTerminate` hook call
/// `shutdownAll()` directly, guaranteeing no orphaned `devicectl` on a
/// clean exit. A crashed daemon's orphan self-exits at `--session-timeout`
/// and is reaped on the next daemon launch (`reapOrphans()`), keyed off the
/// unique notification name.
public final class TunnelKeepalive: @unchecked Sendable {
    /// Spawns the keepalive subprocess for a device, or `nil` if launch
    /// failed (the tunnel then never comes up and the attach poll surfaces
    /// a clean error). Injectable for tests.
    typealias Spawner = @Sendable (_ udid: String) -> KeepaliveHandle?

    private struct Entry {
        var handle: KeepaliveHandle
        var refCount: Int
    }

    /// The Darwin notification the keepalive observes. It never fires;
    /// observing just parks the session. Unique so a crashed daemon's
    /// orphaned keepalives are identifiable for `reapOrphans()`, and so we
    /// never disturb a notification a real client cares about.
    static let notificationName = "com.deviceterm.tunnel.keepalive"

    /// `--session-timeout` for the observe subprocess. Long enough to
    /// outlast any realistic mirror session (so the tunnel never drops
    /// mid-mirror, since there is no respawn), bounded so a crashed-daemon
    /// orphan that escaped the startup reap self-exits within a day.
    static let sessionTimeoutSeconds = 86_400
    private static let reapQueue = BlockingWorkQueue(
        label: "com.deviceterm.daemon.tunnel-reap"
    )

    private let queue = DispatchQueue(label: "com.deviceterm.tunnel-keepalive")
    private let spawn: Spawner
    private var entries: [String: Entry] = [:]

    /// Number of devices currently held (one entry per device regardless of
    /// ref-count). Test/diagnostic.
    var heldDeviceCount: Int {
        queue.sync { entries.count }
    }

    /// Production: borrows `devicectl` to hold tunnels (cross-module: the
    /// daemon's composition root constructs this).
    public init() {
        self.spawn = TunnelKeepalive.defaultSpawner
    }

    /// Hermetic tests: inject a fake spawner so ref-counting / kill logic
    /// runs without a real `devicectl`.
    init(spawner: @escaping Spawner) {
        self.spawn = spawner
    }

    /// SIGINT any keepalive `devicectl` left over from a previously-crashed
    /// daemon, identified by our unique notification name in its argv.
    /// Best-effort; called once at daemon startup. Never touches the calling
    /// process. The process and pipe waits run outside Swift's cooperative
    /// executor.
    public static func reapOrphans() async {
        await reapQueue.run { reapOrphansSynchronously() }
    }

    private static func reapOrphansSynchronously() {
        let pgrep = Process()
        pgrep.launchPath = "/usr/bin/pgrep"
        pgrep.arguments = ["-f", notificationName]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = FileHandle.nullDevice
        do {
            try pgrep.run()
        } catch {
            return
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        pgrep.waitUntilExit()
        let selfPid = ProcessInfo.processInfo.processIdentifier
        let pids = (String(bytes: data, encoding: .utf8) ?? "")
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 != selfPid }
        for pid in pids { kill(pid, SIGINT) }
    }

    private static func defaultSpawner(udid: String) -> KeepaliveHandle? {
        let process = Process()
        process.launchPath = "/usr/bin/xcrun"
        process.arguments = [
            "devicectl", "device", "notification", "observe",
            "--device", udid,
            "--name", TunnelKeepalive.notificationName,
            "--session-timeout", String(TunnelKeepalive.sessionTimeoutSeconds),
            "--timeout", String(TunnelKeepalive.sessionTimeoutSeconds + 300)
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return process
        } catch {
            let line = "deviceterm-daemon: failed to start tunnel keepalive for \(udid): \(error)\n"
            FileHandle.standardError.write(Data(line.utf8))
            return nil
        }
    }

    /// Ensure a tunnel-holding subprocess is running for `udid` and record
    /// one unit of interest. Idempotent per device: the second mirror of
    /// the same device just bumps the ref-count. A dead/failed handle is
    /// respawned on the next retain.
    func retain(udid: String) {
        queue.sync {
            if var entry = entries[udid], entry.handle.isRunning {
                entry.refCount += 1
                entries[udid] = entry
                return
            }
            guard let handle = spawn(udid) else { return }
            entries[udid] = Entry(handle: handle, refCount: 1)
        }
    }

    /// Drop one unit of interest; when the last mirror of `udid` releases,
    /// SIGINT the subprocess so the OS tears the tunnel down. A release with
    /// no matching retain is a no-op.
    func release(udid: String) {
        queue.sync {
            guard var entry = entries[udid] else { return }
            entry.refCount -= 1
            if entry.refCount <= 0 {
                if entry.handle.isRunning { entry.handle.interrupt() }
                entries.removeValue(forKey: udid)
            } else {
                entries[udid] = entry
            }
        }
    }

    /// SIGINT every keepalive and forget them. Called from the daemon's
    /// synchronous termination hook so a clean exit never orphans a
    /// `devicectl` process.
    public func shutdownAll() {
        queue.sync {
            for entry in entries.values where entry.handle.isRunning {
                entry.handle.interrupt()
            }
            entries.removeAll()
        }
    }
}
