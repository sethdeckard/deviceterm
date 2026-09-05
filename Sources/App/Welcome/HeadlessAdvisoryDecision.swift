// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Whether the Simulator.app coexistence alert
/// fires, and which hazard it should name.
///
/// Pure, so the whole gate table is unit testable without AppKit.
/// `HeadlessAdvisoryViewModel` supplies the state and
/// `HeadlessAdvisory` renders the result.
///
/// The expensive inputs arrive as closures rather than values so the
/// cheap gates can short-circuit before an `NSRunningApplication` scan or
/// a cross-process preferences read happens. Ordering is part of the
/// contract here, not an implementation detail, and a test pins it by
/// counting calls.
enum HeadlessAdvisoryDecision: Equatable {
    case skip
    case warn(hazard: SimulatorShutdownHazard)

    /// Resolve the gates in cheapest-first order.
    ///
    /// - Parameters:
    ///   - isPhysicalDevice: a physical-device pane, which Simulator.app
    ///     has nothing to do with. Simulator.app attaches to sims, so a
    ///     device pane can't be exposed to it however the app is
    ///     configured.
    ///   - advisoryShownThisLaunch: any coexistence advisory already
    ///     appeared this launch, this one or Device Hub's. Shared, so two
    ///     of them can't stack on a single pane attach. See
    ///     `CoexistenceAdvisoryLatch`.
    ///   - welcomeShownThisLaunch: a welcome already explained this
    ///     model in this session. Stacking an alert on top of an
    ///     explanation the user is still reading gets both dismissed
    ///     unread, so the alert yields.
    ///   - isSuppressed: the user ticked "Don't show again".
    ///   - isSimulatorAppRunning: no Simulator.app, no coexistence.
    ///   - policy: Simulator.app's detach preferences. When both are
    ///     set there is no hazard left to warn about.
    ///   - deviceHubWillWarn: Device Hub's advisory would also fire.
    ///     This one yields, because only one coexistence warning appears
    ///     per launch and Device Hub's hazard reaches further: quitting
    ///     it shuts down every booted Simulator, including ones it never
    ///     opened, where Simulator.app's reach is bounded by the device
    ///     windows it attached.
    ///
    ///     The priority is a gate rather than a call order. Sequencing
    ///     the two presenters would decide it by which statement runs
    ///     first, which is invisible from here and silently starves
    ///     whichever loses: the loser never fires, in this launch or any
    ///     later one, because nothing rotates.
    static func resolve(
        isPhysicalDevice: Bool,
        advisoryShownThisLaunch: Bool,
        welcomeShownThisLaunch: Bool,
        isSuppressed: () -> Bool,
        isSimulatorAppRunning: () -> Bool,
        policy: () -> SimulatorDetachPolicy,
        deviceHubWillWarn: () -> Bool
    ) -> HeadlessAdvisoryDecision {
        // First, and cheapest: Simulator.app cannot expose a physical
        // device, so the sim-coexistence copy would be describing
        // something that did not happen.
        guard !isPhysicalDevice else { return .skip }
        guard !advisoryShownThisLaunch else { return .skip }
        guard !welcomeShownThisLaunch else { return .skip }
        guard !isSuppressed() else { return .skip }
        guard isSimulatorAppRunning() else { return .skip }
        guard let hazard = hazard(for: policy()) else { return .skip }
        // Last, because it costs a second running-application scan: only
        // ask about Device Hub once this advisory would otherwise fire.
        guard !deviceHubWillWarn() else { return .skip }
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
