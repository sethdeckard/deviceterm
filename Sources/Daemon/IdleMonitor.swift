// SPDX-License-Identifier: GPL-3.0-or-later
//
// IdleMonitor: the daemon's stay-alive predicate evaluator.
//
// The daemon is lazy-spawn: the GUI's XPC traffic demand-launches it
// (the LaunchAgent declares the mach service, not the UDS socket, so CLI
// traffic never starts one), and it keeps itself alive while any of
// these are true:
//
//   - A GUI (XPC) client is connected.
//   - A CLI (UDS) client is connected.
//   - A non-terminal pane exists whose owner GUI is still alive, so a
//     mirror (sim or physical device) survives a momentary connection
//     lapse, but a pane abandoned by a crashed GUI does not pin the daemon.
//   - Any deviceterm-owned sim is booted.
//
// When no poll has observed any of these busy for `idleTimeoutSeconds`,
// the monitor calls its `terminate` handler. Sampling is discrete (see
// the polling cadence below), so busy activity that starts and ends
// entirely between two polls is never observed. The guarantee is
// "no sampled activity for the timeout," not "continuously idle." In
// production
// that handler calls `NSApp.terminate(nil)` so the runloop unwinds
// cleanly; tests inject a closure that records the call without
// touching AppKit.
//
// Polling cadence: every `pollIntervalSeconds` (default 30s). Each
// poll asks `isBusy` for the current verdict. A busy poll resets
// `lastBusyTime`. An idle poll checks `now - lastBusyTime` against
// the timeout. The grace window means a transient lull (e.g. GUI
// disconnect + reconnect within a few seconds) doesn't trigger
// shutdown.

import Foundation

public actor IdleMonitor {
    public typealias BusyPredicate = @Sendable () async -> Bool
    public typealias TerminateHandler = @Sendable () async -> Void

    private let isBusy: BusyPredicate
    private let terminate: TerminateHandler
    private let idleTimeoutSeconds: TimeInterval
    private let pollIntervalSeconds: TimeInterval
    private let clock: @Sendable () -> Date
    private var lastBusyTime: Date
    private var monitorTask: Task<Void, Never>?
    private var hasTerminated: Bool = false

    /// Seconds since the predicate was last true. Used by tests +
    /// (eventually) diagnostics.
    public var idleSeconds: TimeInterval {
        clock().timeIntervalSince(lastBusyTime)
    }

    /// Whether `terminate` has been invoked. Latched so multiple
    /// idle ticks don't re-fire it.
    public var didTerminate: Bool { hasTerminated }

    public init(
        idleTimeoutSeconds: TimeInterval = 60,
        pollIntervalSeconds: TimeInterval = 30,
        clock: @escaping @Sendable () -> Date = { Date() },
        isBusy: @escaping BusyPredicate,
        terminate: @escaping TerminateHandler
    ) {
        self.idleTimeoutSeconds = idleTimeoutSeconds
        self.pollIntervalSeconds = pollIntervalSeconds
        self.clock = clock
        self.isBusy = isBusy
        self.terminate = terminate
        // Seed with `now` so a freshly-spawned daemon gets a full
        // grace window before the first idle check can fire, since we
        // don't want the runloop to terminate the daemon during its
        // own setup if `isBusy` happens to be false at t=0.
        self.lastBusyTime = clock()
    }

    /// Begin polling on the actor's executor. Idempotent.
    public func start() {
        guard monitorTask == nil, !hasTerminated else { return }
        monitorTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Stop polling. Idempotent. Used by tests + by the daemon's
    /// own shutdown path (after `terminate` fires).
    public func stop() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    /// Run one check immediately. Public for tests and for any code
    /// path that wants to short-circuit the next poll (e.g. a GUI
    /// disconnect can call this to fast-forward the predicate check
    /// rather than waiting up to 30s).
    public func tick() async {
        guard !hasTerminated else { return }
        if await isBusy() {
            lastBusyTime = clock()
            return
        }
        let idle = clock().timeIntervalSince(lastBusyTime)
        if idle >= idleTimeoutSeconds {
            hasTerminated = true
            stop()
            await terminate()
        }
    }

    private func runLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(
                nanoseconds: UInt64(pollIntervalSeconds * 1_000_000_000)
            )
            if Task.isCancelled { return }
            await tick()
        }
    }
}
