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
func rpcMethodCaseCountIs71() {
    #expect(RPCMethod.allCases.count == 71)
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
    (RPCMethod.tabsList, "tabs.list"),
    (RPCMethod.panesList, "panes.list"),
    (RPCMethod.shimEvent, "shim.event"),
    (RPCMethod.deviceList, "device.list"),
    (RPCMethod.deviceBoot, "device.boot"),
    (RPCMethod.deviceShutdown, "device.shutdown"),
    (RPCMethod.deviceAttach, "device.attach"),
    (RPCMethod.deviceReconcileBootClaim, "device.reconcileBootClaim"),
    (RPCMethod.deviceRestoreOwnership, "device.restoreOwnership"),
    (RPCMethod.paneCreate, "pane.create"),
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
    (RPCMethod.tabOpen, "tab.open"),
    (RPCMethod.tabClose, "tab.close"),
    (RPCMethod.tabRename, "tab.rename"),
    (RPCMethod.tabSelect, "tab.select"),
    (RPCMethod.tabInfo, "tab.info"),
    (RPCMethod.tabMove, "tab.move"),
    (RPCMethod.paneOpenTerminal, "pane.openTerminal"),
    (RPCMethod.paneClose, "pane.close"),
    (RPCMethod.paneRename, "pane.rename"),
    (RPCMethod.paneInfo, "pane.info"),
    (RPCMethod.paneMove, "pane.move"),
    (RPCMethod.paneAttach, "pane.attach"),
    (RPCMethod.windowOpen, "window.open"),
    (RPCMethod.windowClose, "window.close"),
    (RPCMethod.windowFocus, "window.focus"),
    (RPCMethod.windowsList, "windows.list"),
    (RPCMethod.tabSendInput, "tab.sendInput"),
    (RPCMethod.tabCapture, "tab.capture"),
    (RPCMethod.sessionSetProtectedBatch, "session.setProtectedBatch"),
    (RPCMethod.sessionProtectionSnapshot, "session.protectionSnapshot"),
    (RPCMethod.sessionSetDisplayTitle, "session.setDisplayTitle"),
    (RPCMethod.sessionSetCohort, "session.setCohort"),
    (RPCMethod.tabSetProtected, "tab.setProtected")
    ]
    )
func rpcMethodRawValue(method: RPCMethod, wire: String) {
    #expect(method.rawValue == wire)
}
