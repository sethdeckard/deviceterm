// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import Foundation
import Testing

// PeerIdentity self-mirror parsing: exercises the pure helpers
// (`expectedHostBundleID`, `isSiblingPath`) without needing real
// signed binaries. The runtime `validateGUIPeer` path lives behind
// `SecCodeCopyGuestWithAttributes` and a live audit token, so its
// coverage rides the signed-bundle manual track
// (`Tests/Manual/launchd-xpc-coexistence.md` §4).

@Test
func expectedHostBundleIDStripsDaemonSuffix() {
    let derived = PeerIdentity.expectedHostBundleID(
        daemonBundleID: "com.deviceterm.daemon"
    )
    #expect(derived == "com.deviceterm")
}

@Test
func expectedHostBundleIDPassesThroughWhenNoSuffix() {
    // A daemon whose bundle id doesn't end in `.daemon` keeps the
    // value verbatim, since the host bundle id equals the daemon bundle
    // id by convention.
    let derived = PeerIdentity.expectedHostBundleID(
        daemonBundleID: "me.example.tool"
    )
    #expect(derived == "me.example.tool")
}

@Test
func siblingPathSameDirectoryAccepted() {
    let daemonDir = URL(fileURLWithPath: "/Applications/DeviceTerm.app/Contents/MacOS")
    let peerExecutable = URL(
        fileURLWithPath: "/Applications/DeviceTerm.app/Contents/MacOS/deviceterm"
    )
    #expect(PeerIdentity.isSiblingPath(
        peerExecutable: peerExecutable,
        daemonDir: daemonDir
    ))
}

@Test
func siblingPathSameBundleAcrossLoginItemsAccepted() {
    // Realistic layout: daemon lives under
    // `DeviceTerm.app/Contents/Library/LoginItems/deviceterm-daemon.app`
    // while the host is under `DeviceTerm.app/Contents/MacOS`. Both
    // share the `DeviceTerm.app` ancestor.
    let daemonDir = URL(
        fileURLWithPath: "/Applications/DeviceTerm.app/Contents/Library/LoginItems/"
        + "deviceterm-daemon.app/Contents/MacOS"
    )
    let peerExecutable = URL(
        fileURLWithPath: "/Applications/DeviceTerm.app/Contents/MacOS/deviceterm"
    )
    #expect(PeerIdentity.isSiblingPath(
        peerExecutable: peerExecutable,
        daemonDir: daemonDir
    ))
}

@Test
func siblingPathUnrelatedTreeRejected() {
    let daemonDir = URL(fileURLWithPath: "/Applications/DeviceTerm.app/Contents/MacOS")
    let peerExecutable = URL(fileURLWithPath: "/usr/bin/some-tool")
    #expect(!PeerIdentity.isSiblingPath(
        peerExecutable: peerExecutable,
        daemonDir: daemonDir
    ))
}
