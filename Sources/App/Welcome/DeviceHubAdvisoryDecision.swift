// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Whether the Device Hub coexistence alert fires, and which hazard it
/// should name.
///
/// Pure, so the whole gate table is unit testable without AppKit.
/// `DeviceHubAdvisoryViewModel` supplies the state and `DeviceHubAdvisory`
/// renders the result.
///
/// The expensive input arrives as a closure rather than a value so the
/// cheap gates can short-circuit before an `NSRunningApplication` scan
/// happens. Ordering is part of the contract here, not an implementation
/// detail, and a test pins it by counting calls.
///
/// Simpler than `HeadlessAdvisoryDecision` in one way: there is no
/// preference to read. Simulator.app can be configured to detach, which is
/// why that decision consults a policy and can find no hazard left. Device
/// Hub's shutdown-on-quit has no reachable setting, and ⌥ at quit is a
/// one-time override rather than a saved default, so a reachable pane and
/// a running Device Hub always mean a live hazard.
enum DeviceHubAdvisoryDecision: Equatable {
    case skip
    case warn(hazard: DeviceHubHazard)

    /// Resolve the gates in cheapest-first order.
    ///
    /// - Parameters:
    ///   - isPhysicalDevice: which hazard applies. A sim pane is exposed
    ///     to the quit-shuts-everything-down behavior; a device pane is
    ///     exposed to exclusive control.
    ///   - advisoryShownThisLaunch: any coexistence advisory already
    ///     appeared this launch. Shared across advisories, so two of them
    ///     can't stack on one pane attach. See `CoexistenceAdvisoryLatch`.
    ///   - welcomeShownThisLaunch: a welcome already explained this model
    ///     in this session. Stacking an alert on top of an explanation the
    ///     user is still reading gets both dismissed unread, so the alert
    ///     yields.
    ///   - isSuppressed: the user ticked "Don't show again".
    ///   - isDeviceHubRunning: no Device Hub, no coexistence.
    static func resolve(
        isPhysicalDevice: Bool,
        advisoryShownThisLaunch: Bool,
        welcomeShownThisLaunch: Bool,
        isSuppressed: () -> Bool,
        isDeviceHubRunning: () -> Bool
    ) -> DeviceHubAdvisoryDecision {
        guard !advisoryShownThisLaunch else { return .skip }
        guard !welcomeShownThisLaunch else { return .skip }
        guard !isSuppressed() else { return .skip }
        guard isDeviceHubRunning() else { return .skip }
        return .warn(hazard: hazard(isPhysicalDevice: isPhysicalDevice))
    }

    /// The hazard a pane of this kind is exposed to. Total: both kinds
    /// have one.
    static func hazard(isPhysicalDevice: Bool) -> DeviceHubHazard {
        isPhysicalDevice ? .deviceControlContention : .simulatorShutdownOnQuit
    }
}
