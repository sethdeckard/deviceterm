// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Stopping CoreSimulator's own service, the rung above restarting the helper.
///
/// `com.apple.CoreSimulator.CoreSimulatorService` is a launchd XPCService in
/// the login user's domain, so stopping it is the whole job: the next client
/// request demand-launches a replacement. Nothing here runs `killall`, which
/// matches a process name and so reaches every login on the machine, where a
/// service target names one job in one domain and cannot.
///
/// Ordering belongs to the caller, and it is the opposite of the intuitive
/// one. Every `SimDevice` the helper holds is a proxy into this service, and
/// the helper has no path that invalidates one whose other end has gone.
/// Stopping the helper first does not avoid that: launchd respawns it at once
/// and the replacement takes proxies into the service still running here, then
/// keeps them after this call kills it.
///
/// So this runs first and the helper is terminated after it. That orders the
/// two attempts and nothing more: this call does not observe the service
/// exiting, nor a replacement coming up, so neither is claimed. See
/// `HelperRecoveryCoordinator.Dependencies`.
enum CoreSimulatorRestart {
    /// What the stop attempt established. Deliberately not "restarted": this
    /// signals the service and launchd starts the replacement on the next
    /// request, so a claim about the replacement would be one this call never
    /// observed.
    enum Outcome: Sendable, Equatable {
        /// The signal landed.
        case stopped
        /// The service target named no loaded job, which is already the state
        /// this was trying to reach: a service that isn't running can't be
        /// holding a wedged one's state.
        case notLoaded
        /// The stop was not confirmed. Covers both a `launchctl` that refused
        /// and a `launchctl` that never ran, so it says nothing about whether
        /// the service is still up: the second case establishes no service
        /// state at all.
        case failed(String)
    }

    /// The launchd job. Xcode 27 renames Simulator.app to Device Hub; it does
    /// not rename the service behind it, so this label spans both.
    static let serviceLabel = "com.apple.CoreSimulator.CoreSimulatorService"

    /// `launchctl`'s exit status for a service target that names no loaded
    /// job. It is separated from a genuine failure because the two want
    /// opposite things from the caller.
    private static let noSuchServiceStatus: Int32 = 113

    private static let commandQueue = DispatchQueue(
        label: "com.deviceterm.coresimulator-restart",
        attributes: .concurrent
    )

    /// Signal the service and report only what the signal established.
    ///
    /// SIGKILL rather than SIGTERM because the case this exists for is a
    /// service that has stopped servicing requests, and a wedged process is
    /// exactly one that may never get round to handling a catchable signal.
    /// Nothing is lost by it: CoreSimulator persists device state on disk, and
    /// the sims die with the service either way.
    static func stopService() async -> Outcome {
        await withCheckedContinuation { continuation in
            commandQueue.async {
                continuation.resume(returning: stopServiceSync())
            }
        }
    }

    /// Synchronous core, isolated from the public surface and run only on
    /// `commandQueue` because `Process.waitUntilExit()` blocks its thread.
    nonisolated private static func stopServiceSync() -> Outcome {
        let target = "user/\(getuid())/\(serviceLabel)"
        let process = Process()
        process.launchPath = "/bin/launchctl"
        process.arguments = ["kill", "SIGKILL", target]
        // launchctl explains a refusal on stderr and prints nothing useful on
        // success, so stderr is the whole diagnostic and stdout is dropped.
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()
        do {
            try process.run()
        } catch {
            return .failed("could not run launchctl: \(error.localizedDescription)")
        }
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        switch process.terminationStatus {
        case 0:
            return .stopped

        case noSuchServiceStatus:
            return .notLoaded

        default:
            let detail = (String(bytes: errorData, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = detail.isEmpty ? "" : ": \(detail)"
            return .failed("launchctl kill exited \(process.terminationStatus)\(suffix)")
        }
    }
}
