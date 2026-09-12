// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Testing

// RPCMethod is the single source of truth for RPC method names. These
// tests pin the wire contract: the exact rawValue strings (changing one
// is a wire-breaking change that must bump DaemonProtocolInfo.wireVersion)
// and the case count. The registry-drift guard (that the daemon's
// registry exposes exactly these names) lives in DaemonTests, which can
// see both modules.

@Test
func rpcMethodCaseCountIs74() {
    #expect(RPCMethod.allCases.count == 74)
}

@Test
func rpcMethodRawValuesAreUnique() {
    let raws = RPCMethod.allCases.map(\.rawValue)
    #expect(Set(raws).count == raws.count)
}

@Test(
    "RPCMethod rawValue is the exact wire string",
    arguments: [
    (RPCMethod.daemonPing, "daemon.ping"),
    (RPCMethod.daemonShutdown, "daemon.shutdown"),
    (RPCMethod.sessionCreate, "session.create"),
    (RPCMethod.sessionClose, "session.close"),
    (RPCMethod.sessionAuthenticate, "session.authenticate"),
    (RPCMethod.sessionBindTerminal, "session.bindTerminal"),
    (RPCMethod.sessionSetProtectedBatch, "session.setProtectedBatch"),
    (RPCMethod.sessionRestoreBatch, "session.restoreBatch"),
    (RPCMethod.sessionProtectionSnapshot, "session.protectionSnapshot"),
    (RPCMethod.sessionSetDisplayTitle, "session.setDisplayTitle"),
    (RPCMethod.sessionSetCohort, "session.setCohort"),
    (RPCMethod.paneDeviceList, "pane.deviceList"),
    (RPCMethod.shimEvent, "shim.event"),
    (RPCMethod.deviceList, "device.list"),
    (RPCMethod.deviceBoot, "device.boot"),
    (RPCMethod.deviceShutdown, "device.shutdown"),
    (RPCMethod.deviceAttach, "device.attach"),
    (RPCMethod.deviceReconcileBootClaim, "device.reconcileBootClaim"),
    (RPCMethod.deviceRestoreOwnership, "device.restoreOwnership"),
    (RPCMethod.physicalDeviceList, "physicalDevice.list"),
    (RPCMethod.physicalDeviceAttach, "physicalDevice.attach"),
    (RPCMethod.devicesList, "devices.list"),
    (RPCMethod.paneCreate, "pane.create"),
    (RPCMethod.paneSetName, "pane.setName"),
    (RPCMethod.paneCloseById, "pane.closeById"),
    (RPCMethod.paneInputTap, "pane.input.tap"),
    (RPCMethod.paneInputTouch, "pane.input.touch"),
    (RPCMethod.paneInputSwipe, "pane.input.swipe"),
    (RPCMethod.paneInputEdgeSwipe, "pane.input.edgeSwipe"),
    (RPCMethod.paneInputEdgeTouch, "pane.input.edgeTouch"),
    (RPCMethod.paneInputLongPress, "pane.input.longPress"),
    (RPCMethod.paneInputKey, "pane.input.key"),
    (RPCMethod.paneInputButton, "pane.input.button"),
    (RPCMethod.paneInputRotate, "pane.input.rotate"),
    (RPCMethod.paneInputPinch, "pane.input.pinch"),
    (RPCMethod.paneInputMultitouch, "pane.input.multitouch"),
    (RPCMethod.paneInputText, "pane.input.text"),
    (RPCMethod.paneInputCrown, "pane.input.crown"),
    (RPCMethod.paneAXTree, "pane.ax.tree"),
    (RPCMethod.paneAXPoint, "pane.ax.point"),
    (RPCMethod.paneAXSweep, "pane.ax.sweep"),
    (RPCMethod.paneLocationSet, "pane.location.set"),
    (RPCMethod.paneLocationState, "pane.location.state"),
    (RPCMethod.paneSubscribe, "pane.subscribe"),
    (RPCMethod.paneSurfaceRelease, "pane.surfaceRelease"),
    (RPCMethod.paneSurfaceDrain, "pane.surfaceDrain"),
    (RPCMethod.daemonEvents, "daemon.events"),
    (RPCMethod.daemonCapabilities, "daemon.capabilities"),
    (RPCMethod.appCommands, "app.commands"),
    (RPCMethod.appCommandResult, "app.commandResult"),
    (RPCMethod.windowList, "window.list"),
    (RPCMethod.windowShow, "window.show"),
    (RPCMethod.windowOpen, "window.open"),
    (RPCMethod.windowFocus, "window.focus"),
    (RPCMethod.windowClose, "window.close"),
    (RPCMethod.tabList, "tab.list"),
    (RPCMethod.tabShow, "tab.show"),
    (RPCMethod.tabOpen, "tab.open"),
    (RPCMethod.tabFocus, "tab.focus"),
    (RPCMethod.tabClose, "tab.close"),
    (RPCMethod.tabRename, "tab.rename"),
    (RPCMethod.tabMove, "tab.move"),
    (RPCMethod.tabProtect, "tab.protect"),
    (RPCMethod.tabUnprotect, "tab.unprotect"),
    (RPCMethod.paneList, "pane.list"),
    (RPCMethod.paneShow, "pane.show"),
    (RPCMethod.paneSplit, "pane.split"),
    (RPCMethod.paneFocus, "pane.focus"),
    (RPCMethod.paneClose, "pane.close"),
    (RPCMethod.paneRename, "pane.rename"),
    (RPCMethod.paneSendInput, "pane.sendInput"),
    (RPCMethod.paneCaptureText, "pane.captureText"),
    (RPCMethod.paneAttach, "pane.attach"),
    (RPCMethod.automationGrant, "automation.grant")
    ]
    )
func rpcMethodRawValue(method: RPCMethod, wire: String) {
    #expect(method.rawValue == wire)
}
