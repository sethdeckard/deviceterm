// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Logs what the daemon is holding, on a fixed cadence.
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
/// trouble finds it without knowing what a normal footprint looks like. The
/// threshold decides phrasing only. Nothing here kills, sheds, or throttles anything: an
/// observer that acts on its own reading is a second failure mode, and the
/// bounds that do the acting live in the paths themselves.
public actor DaemonFootprintMonitor {
    typealias Sampler = @Sendable () async -> DaemonFootprintSample
    typealias Reporter = @Sendable (_ line: String, _ escalated: Bool) -> Void

    /// The default footprint at or above which the log wording escalates.
    static let defaultEscalationBytes: UInt64 = 8 * 1_073_741_824

    private let sample: Sampler
    private let report: Reporter
    private let intervalSeconds: Double
    private let escalationBytes: UInt64
    private var pollTask: Task<Void, Never>?
    /// Bumped by `stop`. A sample suspended across a stop resumes into a
    /// generation that has moved on, and drops its reading.
    private var generation = 0

    /// Sample the running daemon. The counts come from the actors that keep
    /// them, so nothing here has to be maintained twice.
    public init(
        paneCoordinator: PaneCoordinator,
        deviceCoordinator: DeviceCoordinator,
        xpcServer: XPCServer,
        intervalSeconds: Double = 60
    ) {
        self.init(intervalSeconds: intervalSeconds) {
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
                abandonedDeviceReads: await deviceCoordinator.abandonedDeviceReadCount,
                xpcRequestsInFlight: await xpcServer.inFlightRequestCount,
                xpcConnections: await xpcServer.connectionCount,
                surfaceExhaustionDrops: pools.exhaustionDrops,
                surfaceReuseWhileInUse: pools.reuseWhileInUse,
                delinquentSightings: pools.delinquentObserved
            )
        }
    }

    init(
        intervalSeconds: Double = 60,
        escalationBytes: UInt64 = DaemonFootprintMonitor.defaultEscalationBytes,
        sample: @escaping Sampler,
        report: @escaping Reporter = { line, escalated in
            if escalated {
                DiagnosticLog.footprint.notice("footprint high: \(line, privacy: .public)")
            } else {
                DiagnosticLog.footprint.notice("\(line, privacy: .public)")
            }
        }
    ) {
        self.intervalSeconds = intervalSeconds
        self.escalationBytes = escalationBytes
        self.sample = sample
        self.report = report
    }

    deinit { pollTask?.cancel() }

    /// Begin sampling. Idempotent; a second call keeps the first task.
    ///
    /// The first sample is taken after one interval, not at startup.
    public func start() {
        guard pollTask == nil else { return }
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
    func tick() async {
        let started = generation
        let reading = await sample()
        // Sampling suspends, and a stop landing inside that window cannot
        // reach a suspension already in flight. Without this the reading
        // resumes and reports after `stop()` has already returned.
        guard !Task.isCancelled, generation == started else { return }
        let escalated = (reading.footprintBytes ?? 0) >= escalationBytes
        report(reading.summary, escalated)
    }
}
