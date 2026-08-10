// SPDX-License-Identifier: GPL-3.0-or-later
//
// DevicePaneState: pins that a device pane carries the backend-neutral
// `MirroredPaneState` shape, so it renders + drives through the same VC as a
// sim once the attach/reconcile path mounts it.

@testable import App
import DaemonProtocol
import Testing

private let deviceCaps = PaneCapabilities(
    touch: true,
    key: true,
    text: true,
    button: true,
    rotate: true,
    crown: false,
    accessibility: false,
    location: true
)

@Test
func devicePaneStateExposesNeutralIdentityAndCapabilities() {
    let state = DevicePaneState(
        paneId: "P1",
        deviceId: "fd00::1",
        displayName: "iPhone 16 Pro",
        family: DeviceFamily.unknown.rawValue,
        shortId: "abc123",
        capabilities: deviceCaps
    )
    let neutral: any MirroredPaneState = state
    #expect(neutral.target == .device(deviceId: "fd00::1"))
    #expect(neutral.paneId == "P1")
    #expect(neutral.capabilities == deviceCaps)
}

@Test
func simPaneStateConformsToMirroredPaneStateWithSimTarget() {
    let state = SimPaneState(paneId: "P2", udid: "udid-1", displayName: "iPhone 17", family: "phone")
    let neutral: any MirroredPaneState = state
    #expect(neutral.target == .sim(udid: "udid-1"))
}
