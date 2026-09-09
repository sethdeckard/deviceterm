// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import DeviceTermUITest

/// The harness holds Screen Recording and Accessibility because it observes
/// deviceterm. A request names its own target, so these pin that a foreign one
/// is refused rather than acted on: without the check the resident lends both
/// grants to any app on the machine, reachable by every process running as the
/// same user.
///
/// Hermetic by construction. The refusal happens before any accessibility read
/// or capture, so these need no grant, no GUI, and no running deviceterm.
@Suite("harness target scope")
struct ResponderTargetTests {
    private let foreign = "com.apple.finder"

    private func reply(
        _ method: UITestMethod,
        _ params: [String: String]
    ) async throws -> [String: Any] {
        let data = await Responder().respond(to: UITestRequest(method: method, params: params))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func refusal(of object: [String: Any]) throws -> String {
        #expect(object["ok"] as? Bool == false)
        return try #require(object["error"] as? String)
    }

    @Test
    func axDumpRefusesAForeignTarget() async throws {
        let error = try refusal(of: try await reply(.axDump, ["bundleId": foreign]))
        #expect(error.contains(foreign))
        #expect(error.contains(DeviceTermBundleID.app))
    }

    @Test
    func captureWindowRefusesAForeignTarget() async throws {
        let object = try await reply(.captureWindow, ["bundleId": foreign, "out": "/tmp/x.png"])
        #expect(try refusal(of: object).contains(foreign))
    }

    /// The sharpest of the four: the shipped CLI has no `--bundle-id` for
    /// `drive`, so this is reachable only over the socket, and it is input
    /// injection rather than observation.
    @Test
    func driveKeyRefusesAForeignTarget() async throws {
        let object = try await reply(.driveKey, ["bundleId": foreign, "shortcut": "cmd+t"])
        #expect(try refusal(of: object).contains(foreign))
    }

    @Test
    func driveClickRefusesAForeignTarget() async throws {
        let object = try await reply(.driveClick, ["bundleId": foreign, "ax": "Cancel"])
        #expect(try refusal(of: object).contains(foreign))
    }

    /// A malformed request must not become a way past the check: the target is
    /// resolved before the method's own parameters are validated, except where
    /// a missing parameter is refused first and never reaches a target at all.
    @Test
    func aForeignTargetIsRefusedEvenWithoutTheMethodsOwnParameters() async throws {
        let object = try await reply(.driveClick, ["bundleId": foreign])
        #expect(try refusal(of: object).contains(foreign))
    }

    /// deviceterm and its daemon are the whole allow-list. The daemon is not
    /// incidental: `ax dump --bundle-id com.deviceterm.daemon` is how the
    /// status-item badge is read, so dropping it would break that check.
    @Test
    func onlyDevicetermAndItsDaemonAreTargets() {
        #expect(DeviceTermBundleID.targets == [DeviceTermBundleID.app, DeviceTermBundleID.daemon])
    }
}
