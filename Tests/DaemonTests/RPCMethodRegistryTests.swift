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
