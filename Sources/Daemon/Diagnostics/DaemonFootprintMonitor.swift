// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// Logs what the daemon is holding, on a fixed cadence, and ends the process
/// cleanly if that grows past a ceiling.
///
/// Periodic samples preserve the resource counts needed to diagnose abnormal
/// daemon growth. It records counters the actors already maintain rather than
/// keeping parallel bookkeeping of its own.
///
/// Sampling runs once per configured interval and does work proportional to
/// live and retiring panes, their subscribers, and XPC connections. It adds no
/// frame-path work. It logs at `.notice` because `.info` does not survive
/// `log show` without `--info`, and a sample nobody can retrieve afterwards is
/// the gap this closes.
///
/// At or above `escalationBytes` the wording changes so a reader scanning for
/// trouble finds it without knowing what a normal footprint looks like, and
/// the first such sample is followed by a breakdown of where the memory sits.
/// At or above `ceilingBytes` the monitor stops sampling, writes the breakdown
/// again, and hands off to `terminate`, which exits the process cleanly. That
/// exit is the one action taken here, and it is taken because the
/// alternative is worse: the GUI treats a clean exit as a helper restart and
/// re-attaches every pane, whereas the kernel's own kill arrives at a
/// footprint many times larger, after the machine has been paging and every
/// mirror has already frozen. The ceiling bounds the whole process; the
/// bounds that act on any one path still live in that path.
public actor DaemonFootprintMonitor {
    typealias Sampler = @Sendable () async -> DaemonFootprintSample
    typealias Reporter = @Sendable (_ line: String, _ kind: Report) -> Void
    /// Lines describing where the footprint sits; empty when unavailable.
    typealias BreakdownProvider = @Sendable () -> [String]
    /// Runs once, after sampling has stopped. `reason` names the reading and
    /// the ceiling it crossed.
    public typealias TerminateHandler = @Sendable (_ reason: String) async -> Void

    /// Which kind of line a report carries, so the logger can prefix it.
    enum Report: Sendable, Equatable {
        case sample
        case high
        case breakdown
    }

    /// The default footprint at or above which the log wording escalates.
    static let defaultEscalationBytes: UInt64 = 1_073_741_824
    /// The default footprint at or above which the daemon exits.
    static let defaultCeilingBytes: UInt64 = 2 * 1_073_741_824

    private let sample: Sampler
    private let report: Reporter
    private let breakdown: BreakdownProvider
    private let terminate: TerminateHandler
    private let intervalSeconds: Double
    private let escalationBytes: UInt64
    /// Nil disables the ceiling.
    private let ceilingBytes: UInt64?
    private var pollTask: Task<Void, Never>?
    /// Bumped by `stop`. A sample suspended across a stop resumes into a
    /// generation that has moved on, and drops its reading.
    private var generation = 0
    /// Latched by the breach. Sampling ends there, and no later tick or
    /// `start` can hand off a second time.
    private var hasBreached = false
    private var hasLoggedEscalationBreakdown = false

    var didBreachCeiling: Bool { hasBreached }

    /// Sample the running daemon. The counts come from the actors that keep
    /// them, so nothing here has to be maintained twice.
    public init(
        paneCoordinator: PaneCoordinator,
        deviceCoordinator: DeviceCoordinator,
        xpcServer: XPCServer,
        ceilingBytes: UInt64?,
        terminate: @escaping TerminateHandler,
        intervalSeconds: Double = 60
    ) {
        self.init(
            intervalSeconds: intervalSeconds,
            ceilingBytes: ceilingBytes,
            sample: {
                let counts = await paneCoordinator.paneCounts()
                let queue = await paneCoordinator.subscriptionQueueDepth()
                let pools = await paneCoordinator.poolCountersTotal()
                return DaemonFootprintSample(
                    footprintBytes: ProcessFootprint.physFootprintBytes(),
                    panes: counts.live,
                    retiringPanes: counts.retiring,
                    subscribers: await paneCoordinator.totalSubscriberCount(),
                    pendingPaneEvents: queue.pending,
                    conflatedSurfaceNotices: queue.conflated,
                    acquiresInFlight: await paneCoordinator.acquiresInFlight(),
                    displayStartsInFlight: await paneCoordinator.displayStartsInFlight(),
                    reservedTargets: await paneCoordinator.creatingCount,
                    abandonedDeviceReads: await deviceCoordinator.abandonedDeviceReadCount,
                    xpcRequestsInFlight: await xpcServer.inFlightRequestCount,
                    xpcConnections: await xpcServer.connectionCount,
                    surfaceExhaustionDrops: pools.exhaustionDrops,
                    surfaceReuseWhileInUse: pools.reuseWhileInUse,
                    delinquentSightings: pools.delinquentObserved,
                    inputSubmissions: await paneCoordinator.inputSubmissionsTotal()
                )
            },
            breakdown: { MemoryBreakdownReader.read().lines() },
            terminate: terminate
        )
    }

    init(
        intervalSeconds: Double = 60,
        escalationBytes: UInt64 = DaemonFootprintMonitor.defaultEscalationBytes,
        ceilingBytes: UInt64? = nil,
        sample: @escaping Sampler,
        breakdown: @escaping BreakdownProvider = { [] },
        report: @escaping Reporter = { line, kind in
            switch kind {
            case .sample:
                DiagnosticLog.footprint.notice("\(line, privacy: .public)")

            case .high:
                DiagnosticLog.footprint.notice("footprint high: \(line, privacy: .public)")

            case .breakdown:
                DiagnosticLog.footprint.notice("footprint breakdown: \(line, privacy: .public)")
            }
        },
        terminate: @escaping TerminateHandler = { _ in }
    ) {
        self.intervalSeconds = intervalSeconds
        self.escalationBytes = escalationBytes
        self.ceilingBytes = ceilingBytes
        self.sample = sample
        self.breakdown = breakdown
        self.report = report
        self.terminate = terminate
    }

    deinit { pollTask?.cancel() }

    /// The ceiling the environment asks for, in bytes.
    ///
    /// Unset keeps the default. `0` disables the ceiling. Anything that is
    /// not a whole number of MiB keeps the default rather than failing, the
    /// same way the other tuning keys fall back.
    public static func ceilingBytes(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> UInt64? {
        guard let raw = environment[DeviceTermEnv.footprintCeilingMiB],
            let mebibytes = UInt64(raw)
        else { return defaultCeilingBytes }
        if mebibytes == 0 { return nil }
        let (bytes, overflow) = mebibytes.multipliedReportingOverflow(by: 1_048_576)
        return overflow ? defaultCeilingBytes : bytes
    }

    /// Begin sampling. Idempotent; a second call keeps the first task, and a
    /// call after the breach installs nothing.
    ///
    /// The first sample is taken after one interval, not at startup.
    public func start() {
        guard pollTask == nil, !hasBreached else { return }
        let interval = intervalSeconds
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { return }
                await self?.tick()
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        generation &+= 1
    }

    /// Take one sample and log it, unless the monitor stopped while the
    /// sample was in flight. Called directly by tests; the poll calls it on
    /// the cadence.
    ///
    /// An unreadable footprint reads as zero here, so it can neither escalate
    /// nor breach: the sample line already says it is unknown.
    func tick() async {
        guard !hasBreached else { return }
        let started = generation
        let reading = await sample()
        // Sampling suspends, and a stop landing inside that window cannot
        // reach a suspension already in flight. Without this the reading
        // resumes and reports after `stop()` has already returned.
        guard !Task.isCancelled, generation == started, !hasBreached else { return }
        let bytes = reading.footprintBytes ?? 0
        let escalated = bytes >= escalationBytes
        report(reading.summary, escalated ? .high : .sample)
        let breached = ceilingBytes.map { bytes >= $0 } ?? false
        if escalated, !breached, !hasLoggedEscalationBreakdown {
            hasLoggedEscalationBreakdown = true
            logBreakdown()
        }
        guard breached, let ceilingBytes, let footprint = reading.footprintBytes else { return }
        hasBreached = true
        stop()
        logBreakdown()
        await terminate(
            "footprint=\(footprint / 1_048_576)MiB ceiling=\(ceilingBytes / 1_048_576)MiB"
        )
    }

    private func logBreakdown() {
        for line in breakdown() {
            report(line, .breakdown)
        }
    }
}
