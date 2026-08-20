// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import TerminalProvenance
import Testing
#if canImport(Darwin)
import Darwin
#endif

// TerminalProbe: Darwin-backed negative-path coverage of the anchor
// derivation. A positive derivation needs a real controlling terminal (covered
// by the GUI integration/manual gate, since `make test` runs with no
// controlling tty); these lock the fail-closed syscall plumbing so a wrong
// stat/char-device/e_tdev check can't silently pass.

#if canImport(Darwin)
@Test
func probeRejectsNonCharacterDeviceTTY() {
    // A regular file is not a character device → nil.
    #expect(DefaultTerminalProbe.derive(foregroundPid: getpid(), ttyName: "/etc/hosts") == nil)
}

@Test
func probeRejectsForegroundControllingTTYMismatch() {
    // /dev/null IS a character device, but this process' controlling tty is
    // never /dev/null, so the foreground e_tdev cross-check fails → nil.
    #expect(DefaultTerminalProbe.derive(foregroundPid: getpid(), ttyName: "/dev/null") == nil)
}

@Test
func probeRejectsDeadForegroundPid() {
    // A pid with no live process fails the proc_pidinfo lookup → nil, even
    // though the tty is a valid character device.
    #expect(DefaultTerminalProbe.derive(foregroundPid: 999_999, ttyName: "/dev/null") == nil)
}

@Test
func probeRejectsMissingTTYPath() {
    #expect(DefaultTerminalProbe.derive(foregroundPid: getpid(), ttyName: "/nope/not/here") == nil)
}
#endif
