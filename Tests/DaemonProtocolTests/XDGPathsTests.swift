// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import Testing

// XDGPaths resolves config-file locations from the XDG base-directory
// spec. The env is injected so these run without touching the real
// process environment. The contract: honor $XDG_CONFIG_HOME only when
// it's a non-empty absolute path; otherwise fall back to ~/.config.

@Test
func honorsAbsoluteXDGConfigHome() {
    let env = ["XDG_CONFIG_HOME": "/tmp/xdgtest"]
    #expect(XDGPaths.configHome(environment: env) == "/tmp/xdgtest")
    #expect(XDGPaths.deviceTermConfig(environment: env) == "/tmp/xdgtest/deviceterm/config")
    #expect(XDGPaths.deviceTermLocations(environment: env) == "/tmp/xdgtest/deviceterm/locations")
    #expect(XDGPaths.ghosttyConfig(environment: env) == "/tmp/xdgtest/ghostty/config")
}

@Test
func fallsBackWhenUnset() {
    let expected = (NSHomeDirectory() as NSString).appendingPathComponent(".config")
    #expect(XDGPaths.configHome(environment: [:]) == expected)
    #expect(XDGPaths.deviceTermConfig(environment: [:]) == expected + "/deviceterm/config")
    #expect(XDGPaths.deviceTermLocations(environment: [:]) == expected + "/deviceterm/locations")
    #expect(XDGPaths.ghosttyConfig(environment: [:]) == expected + "/ghostty/config")
}

@Test
func ignoresEmptyXDGConfigHome() {
    let expected = (NSHomeDirectory() as NSString).appendingPathComponent(".config")
    #expect(XDGPaths.configHome(environment: ["XDG_CONFIG_HOME": ""]) == expected)
}

@Test
func ignoresRelativeXDGConfigHome() {
    // A relative value is invalid per spec, so fall back rather than
    // resolve a path relative to some ambiguous cwd.
    let expected = (NSHomeDirectory() as NSString).appendingPathComponent(".config")
    #expect(XDGPaths.configHome(environment: ["XDG_CONFIG_HOME": "relative/dir"]) == expected)
}
