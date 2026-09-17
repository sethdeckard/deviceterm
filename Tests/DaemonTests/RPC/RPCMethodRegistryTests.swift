// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import Testing

// Drift guard between the canonical RPCMethod set (DaemonProtocol) and
// the daemon's default registry. They must enumerate exactly the same
// method names: registering a handler whose name has no RPCMethod case,
// or adding a case the registry doesn't wire, fails here. This is the
// test that keeps the single-source-of-truth honest. (It lives in
// DaemonTests rather than DaemonProtocolTests because only this target
// sees both `Daemon` (for `defaultRegistry`) and `DaemonProtocol`.)

@Test
func registryKeysMatchRPCMethodCases() {
    let registry = DaemonMethods.defaultRegistry(
        sessionManager: SessionManager(),
        deviceCoordinator: DeviceCoordinator(),
        paneCoordinator: PaneCoordinator()
    )
    #expect(Set(registry.methodNames) == Set(RPCMethod.allCases.map(\.rawValue)))
}

@Test
func paneNameMirrorIsValidatedGUIOnly() {
    let registry = DaemonMethods.defaultRegistry(
        sessionManager: SessionManager(),
        deviceCoordinator: DeviceCoordinator(),
        paneCoordinator: PaneCoordinator()
    )
    #expect(registry.scope(of: RPCMethod.paneSetName.rawValue) == .validatedGUI)
}

/// `deviceterm doctor` probes CoreSimulator with `device.list` on a connection
/// it deliberately leaves unauthenticated, so that a stale capability or a
/// rejected terminal provenance cannot surface as a wedged CoreSimulator and
/// earn the remedy for one, which stops every simulator on the login. That only
/// holds while the method needs no session, so the scope is pinned here rather
/// than assumed by a caller in another target.
@Test
func deviceListStaysDaemonWideForTheDoctorProbe() {
    let registry = DaemonMethods.defaultRegistry(
        sessionManager: SessionManager(),
        deviceCoordinator: DeviceCoordinator(),
        paneCoordinator: PaneCoordinator()
    )
    #expect(registry.scope(of: RPCMethod.deviceList.rawValue) == .daemonWide)
}

@Test
func registryTagsExactlyTheAutomationSurface() {
    // Which verbs need a live automation grant is a closed set, pinned
    // here so one can't be added or dropped as a side effect. Two groups:
    // verbs that create or rearrange workspace surfaces or change focus,
    // plus two terminal-content verbs. All eight are gated before target
    // resolution.
    let registry = DaemonMethods.defaultRegistry(
        sessionManager: SessionManager(),
        deviceCoordinator: DeviceCoordinator(),
        paneCoordinator: PaneCoordinator()
    )
    let tagged = registry.methodNames.filter { registry.scope(of: $0) == .automationTab }
    let expected: [RPCMethod] = [
        .tabOpen, .tabFocus, .tabMove, .windowOpen, .windowFocus, .paneFocus,
        .paneSendInput, .paneCaptureText
    ]
    #expect(Set(tagged) == Set(expected.map(\.rawValue)))
}
