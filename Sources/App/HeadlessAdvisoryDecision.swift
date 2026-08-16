// SPDX-License-Identifier: GPL-3.0-or-later
//
// HeadlessAdvisoryDecision: whether the Simulator.app coexistence alert
// fires, and which hazard it should name.
//
// Pure, so the whole gate table is unit testable without AppKit.
// `HeadlessAdvisoryViewModel` supplies the state and
// `HeadlessAdvisory` renders the result.
//
// The expensive inputs arrive as closures rather than values so the
// cheap gates can short-circuit before an `NSRunningApplication` scan or
// a cross-process preferences read happens. Ordering is part of the
// contract here, not an implementation detail, and a test pins it by
// counting calls.

import Foundation

/// Which way Simulator.app can still take a booted sim down. Named from
/// the user's action, not the preference key, because that is what the
/// alert has to describe.
enum SimulatorShutdownHazard: Equatable {
    /// Quitting Simulator.app, which includes closing its last device
    /// window: that closes the app, not just the window.
    case appQuit
    /// Closing one device window while others stay open.
    case windowClose
    /// Both routes are live.
    case both
}

enum HeadlessAdvisoryDecision: Equatable {
    case skip
    case warn(hazard: SimulatorShutdownHazard)

    /// Resolve the gates in cheapest-first order.
    ///
    /// - Parameters:
    ///   - shownThisLaunch: the advisory's own once-per-launch latch.
    ///   - welcomeShownThisLaunch: a welcome already explained this
    ///     model in this session. Stacking an alert on top of an
    ///     explanation the user is still reading gets both dismissed
    ///     unread, so the alert yields.
    ///   - isSuppressed: the user ticked "Don't show again".
    ///   - isSimulatorAppRunning: no Simulator.app, no coexistence.
    ///   - policy: Simulator.app's detach preferences. When both are
    ///     set there is no hazard left to warn about.
    static func resolve(
        shownThisLaunch: Bool,
        welcomeShownThisLaunch: Bool,
        isSuppressed: () -> Bool,
        isSimulatorAppRunning: () -> Bool,
        policy: () -> SimulatorDetachPolicy
    ) -> HeadlessAdvisoryDecision {
        guard !shownThisLaunch else { return .skip }
        guard !welcomeShownThisLaunch else { return .skip }
        guard !isSuppressed() else { return .skip }
        guard isSimulatorAppRunning() else { return .skip }
        guard let hazard = hazard(for: policy()) else { return .skip }
        return .warn(hazard: hazard)
    }

    /// The live hazard for a policy, or nil when Simulator.app is
    /// already configured to detach on both routes.
    static func hazard(for policy: SimulatorDetachPolicy) -> SimulatorShutdownHazard? {
        switch (policy.detachOnAppQuit, policy.detachOnWindowClose) {
        case (true, true):
            return nil

        case (false, true):
            return .appQuit

        case (true, false):
            return .windowClose

        case (false, false):
            return .both
        }
    }
}
