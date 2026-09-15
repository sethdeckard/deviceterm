// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Testing

// DeviceTermEnv is the single source of truth for the injected env-var
// names. Pin the exact spellings: the generated zsh dotfiles interpolate
// these, and the shim/CLI/daemon read them, so a typo here would silently
// break in-tab provenance. Guarding the constants keeps that output
// byte-identical without a heavyweight dotfile golden test.
@Test
func deviceTermEnvNames() {
    #expect(DeviceTermEnv.session == "DEVICETERM_SESSION")
    #expect(DeviceTermEnv.sessionCap == "DEVICETERM_SESSION_CAP")
    #expect(DeviceTermEnv.daemonSock == "DEVICETERM_DAEMON_SOCK")
    #expect(DeviceTermEnv.daemonPath == "DEVICETERM_DAEMON_PATH")
    #expect(DeviceTermEnv.shimDir == "DEVICETERM_SHIM_DIR")
    #expect(DeviceTermEnv.bootClaimSock == "DEVICETERM_BOOT_CLAIM_SOCK")
    #expect(DeviceTermEnv.zdotdir == "ZDOTDIR")
}

// The daemon reads its tuning keys from launchd's environment, which an
// operator sets by hand with `launchctl setenv`, so the spelling is part of
// the operating contract.
@Test
func daemonTuningEnvNames() {
    #expect(DeviceTermEnv.footprintCeilingMiB == "DEVICETERM_FOOTPRINT_CEILING_MIB")
}
