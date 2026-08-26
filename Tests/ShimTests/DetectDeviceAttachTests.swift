// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
@testable import Shim
import Testing

// Pin the shim's `devicectl` detection layer: which physical-device
// deploy/run invocations trigger a contextual auto-attach, and which
// `devicectl` (and non-devicectl) invocations must NOT, since otherwise
// the shim would either miss a deploy the user expects mirrored, or fire
// an attach on a read-only query.
//
// The shim parses `--device <id>` verbatim and forwards it to the
// daemon, which resolves it to a connected device. A miss here means
// the app installs/launches but deviceterm never mounts the device pane.

// MARK: - Fixture helper

private func argv(_ invokedAs: String, _ rest: String...) -> [String] {
    [invokedAs] + rest
}

// MARK: - Positive cases: triggers the shim MUST detect

@Test("install — with and without the `app` subnoun", arguments: [
    argv("xcrun", "devicectl", "device", "install", "app", "--device", "iPhone 17 Pro", "/tmp/My.app"),
    argv("xcrun", "devicectl", "device", "install", "--device", "iPhone 17 Pro", "/tmp/My.app")
])
func detectsInstall(input: [String]) {
    #expect(detectDeviceAttach(argv: input, invokedAs: "xcrun") == "iPhone 17 Pro")
}

@Test("process launch — xcrun devicectl device process launch")
func detectsProcessLaunch() {
    let input = argv("xcrun", "devicectl", "device", "process", "launch", "--device", "00008130-DEAD", "com.x.App")
    #expect(detectDeviceAttach(argv: input, invokedAs: "xcrun") == "00008130-DEAD")
}

@Test("--device=<id> equals form")
func detectsEqualsForm() {
    let input = argv("xcrun", "devicectl", "device", "install", "app", "--device=ABCD1234", "/tmp/My.app")
    #expect(detectDeviceAttach(argv: input, invokedAs: "xcrun") == "ABCD1234")
}

@Test("xcrun --sdk flag before devicectl is skipped")
func skipsXcrunFlagsBeforeDevicectl() {
    let input = argv("xcrun", "--sdk", "iphoneos", "devicectl", "device", "install", "--device", "MyPhone", "/a.app")
    #expect(detectDeviceAttach(argv: input, invokedAs: "xcrun") == "MyPhone")
}

// MARK: - Negative cases: invocations the shim must NOT treat as attach

@Test("read-only / lifecycle devicectl subcommands never trigger", arguments: [
    argv("xcrun", "devicectl", "device", "info", "details", "--device", "MyPhone"),
    argv("xcrun", "devicectl", "device", "list"),
    argv("xcrun", "devicectl", "device", "reboot", "--device", "MyPhone"),
    argv("xcrun", "devicectl", "device", "process", "list", "--device", "MyPhone"),
    argv("xcrun", "devicectl", "list", "devices")
])
func ignoresNonDeployDevicectl(input: [String]) {
    #expect(detectDeviceAttach(argv: input, invokedAs: "xcrun") == nil)
}

@Test("install without --device yields nil (no attribution target)")
func installWithoutDeviceFlagIsNil() {
    let input = argv("xcrun", "devicectl", "device", "install", "app", "/tmp/My.app")
    #expect(detectDeviceAttach(argv: input, invokedAs: "xcrun") == nil)
}

@Test("simctl invocations are not devicectl attaches")
func simctlIsNotDeviceAttach() {
    let input = argv("xcrun", "simctl", "boot", "iPhone 17 Pro")
    #expect(detectDeviceAttach(argv: input, invokedAs: "xcrun") == nil)
}

@Test("bare devicectl is not intercepted (only xcrun devicectl reaches the shim)")
func bareDevicectlIsNotDetected() {
    // The shim is symlinked as xcrun/simctl only; main rejects any other
    // argv[0]. A `devicectl …` first token is therefore never the shim's
    // own invocation name, so guard against pretending to support it.
    let input = argv("devicectl", "device", "install", "app", "--device", "MyPhone", "/x.app")
    #expect(detectDeviceAttach(argv: input, invokedAs: "devicectl") == nil)
}

@Test("a devicectl install is not a sim transition either")
func deviceInstallIsNotSimEvent() {
    let input = argv("xcrun", "devicectl", "device", "install", "app", "--device", "MyPhone", "/tmp/My.app")
    #expect(detectEvent(argv: input, invokedAs: "xcrun") == nil)
}
