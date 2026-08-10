// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Foundation
import Testing

// CloseDecisions has two surfaces: `tabClose` (single + bulk) /
// `windowClose` for the close prompt, and `quitWithSims` for the
// quit prompt. Both prompt through `NSAlert.runModal` when no stored
// disposition exists (that path can't run in a non-UI test process),
// but both also short-circuit when a stored disposition exists in
// `CloseSuppressionState` or `~/.config/deviceterm/config`. The
// short-circuit paths are what these tests pin: it's the regression
// class that lets a user's "Don't ask again" stick, and the path that
// makes the scope tiers (window / session / appExit / always) behave
// as advertised.

// MARK: - Persistent file lookup (forever tier)

@MainActor
@Test
func tabCloseHonorsPersistentDetachDefault() throws {
    let fixture = try makeFixture(contents: "tab-close-default = detach\n")
    defer { cleanup(fixture.path) }
    #expect(
        CloseDecisions.tabClose(
            config: fixture.config,
            state: fixture.state,
            context: CloseContext(windowID: nil, hasOtherTabsInWindow: false)
        ) == .detach
    )
}

@MainActor
@Test
func tabCloseHonorsPersistentShutdownDefault() throws {
    let fixture = try makeFixture(contents: "tab-close-default = shutdown\n")
    defer { cleanup(fixture.path) }
    #expect(
        CloseDecisions.tabClose(
            config: fixture.config,
            state: fixture.state,
            context: CloseContext(windowID: nil, hasOtherTabsInWindow: false)
        ) == .shutdown
    )
}

@MainActor
@Test
func windowCloseHonorsPersistentDetachDefault() throws {
    // Window close reuses `tab-close-default` so a single "Don't ask
    // again" applies to both surfaces. Pin the no-prompt path here so
    // the shared key isn't accidentally split into a
    // `window-close-default` regression.
    let fixture = try makeFixture(contents: "tab-close-default = detach\n")
    defer { cleanup(fixture.path) }
    #expect(
        CloseDecisions.windowClose(
            config: fixture.config,
            state: fixture.state,
            windowID: WindowID(value: 1)
        ) == .detach
    )
}

@MainActor
@Test
func windowCloseHonorsPersistentShutdownDefault() throws {
    let fixture = try makeFixture(contents: "tab-close-default = shutdown\n")
    defer { cleanup(fixture.path) }
    #expect(
        CloseDecisions.windowClose(
            config: fixture.config,
            state: fixture.state,
            windowID: WindowID(value: 1)
        ) == .shutdown
    )
}

@MainActor
@Test
func quitWithSimsHonorsPersistentKeepDefault() throws {
    let fixture = try makeFixture(contents: "quit-with-sims-default = keep\n")
    defer { cleanup(fixture.path) }
    #expect(
        CloseDecisions.quitWithSims(config: fixture.config, state: fixture.state) == .keepSims
    )
}

@MainActor
@Test
func quitWithSimsHonorsPersistentShutdownDefault() throws {
    let fixture = try makeFixture(contents: "quit-with-sims-default = shutdown\n")
    defer { cleanup(fixture.path) }
    #expect(
        CloseDecisions.quitWithSims(config: fixture.config, state: fixture.state) == .shutdownSims
    )
}

// MARK: - Lookup precedence (window > session > persistent)

@MainActor
@Test
func perWindowOverrideBeatsPersistent() throws {
    let fixture = try makeFixture(contents: "tab-close-default = shutdown\n")
    defer { cleanup(fixture.path) }
    let windowID = WindowID(value: 7)
    fixture.state.recordClose(
        decision: .detach,
        scope: .window,
        windowID: windowID,
        config: fixture.config
    )
    // Same window → window override wins.
    #expect(
        CloseDecisions.tabClose(
            config: fixture.config,
            state: fixture.state,
            context: CloseContext(windowID: windowID, hasOtherTabsInWindow: true)
        ) == .detach
    )
    // Different window → falls through to persistent.
    #expect(
        CloseDecisions.tabClose(
            config: fixture.config,
            state: fixture.state,
            context: CloseContext(
                windowID: WindowID(value: 8),
                hasOtherTabsInWindow: true
            )
        ) == .shutdown
    )
}

@MainActor
@Test
func sessionOverrideBeatsPersistent() throws {
    let fixture = try makeFixture(contents: "tab-close-default = shutdown\n")
    defer { cleanup(fixture.path) }
    fixture.state.recordClose(
        decision: .detach,
        scope: .session,
        windowID: nil,
        config: fixture.config
    )
    #expect(
        CloseDecisions.tabClose(
            config: fixture.config,
            state: fixture.state,
            context: CloseContext(windowID: WindowID(value: 1), hasOtherTabsInWindow: false)
        ) == .detach
    )
}

@MainActor
@Test
func perWindowOverrideBeatsSession() throws {
    let fixture = try makeFixture(contents: "")
    defer { cleanup(fixture.path) }
    let windowID = WindowID(value: 3)
    fixture.state.recordClose(
        decision: .detach,
        scope: .session,
        windowID: nil,
        config: fixture.config
    )
    fixture.state.recordClose(
        decision: .shutdown,
        scope: .window,
        windowID: windowID,
        config: fixture.config
    )
    #expect(
        CloseDecisions.tabClose(
            config: fixture.config,
            state: fixture.state,
            context: CloseContext(windowID: windowID, hasOtherTabsInWindow: true)
        ) == .shutdown
    )
}

// MARK: - Per-tier writes

@MainActor
@Test
func windowScopeWritesInMemoryOnly() throws {
    let fixture = try makeFixture(contents: "")
    defer { cleanup(fixture.path) }
    let windowID = WindowID(value: 9)
    fixture.state.recordClose(
        decision: .shutdown,
        scope: .window,
        windowID: windowID,
        config: fixture.config
    )
    #expect(fixture.state.perWindow[windowID] == .shutdown)
    // Nothing persisted.
    #expect(ConfigFile(path: fixture.path).value(forKey: CloseDecisions.tabCloseKey) == nil)
}

@MainActor
@Test
func sessionScopeWritesInMemoryOnly() throws {
    let fixture = try makeFixture(contents: "")
    defer { cleanup(fixture.path) }
    fixture.state.recordClose(
        decision: .detach,
        scope: .session,
        windowID: nil,
        config: fixture.config
    )
    #expect(fixture.state.perSession == .detach)
    #expect(ConfigFile(path: fixture.path).value(forKey: CloseDecisions.tabCloseKey) == nil)
}

@MainActor
@Test
func appExitScopeWritesQuitKeyOnly() throws {
    let fixture = try makeFixture(contents: "")
    defer { cleanup(fixture.path) }
    fixture.state.recordQuit(decision: .shutdownSims, scope: .appExit, config: fixture.config)
    let written = ConfigFile(path: fixture.path)
    #expect(written.value(forKey: CloseDecisions.quitWithSimsKey) == "shutdown")
    #expect(written.value(forKey: CloseDecisions.tabCloseKey) == nil)
}

// MARK: - "Always" cross-writes both keys

@MainActor
@Test
func alwaysOnClosePromptWritesBothKeys() throws {
    let fixture = try makeFixture(contents: "")
    defer { cleanup(fixture.path) }
    fixture.state.recordClose(
        decision: .detach,
        scope: .always,
        windowID: nil,
        config: fixture.config
    )
    let written = ConfigFile(path: fixture.path)
    #expect(written.value(forKey: CloseDecisions.tabCloseKey) == "detach")
    // detach ↔ keep cross-mapping for the quit key.
    #expect(written.value(forKey: CloseDecisions.quitWithSimsKey) == "keep")
}

@MainActor
@Test
func alwaysOnClosePromptShutdownWritesBothKeys() throws {
    let fixture = try makeFixture(contents: "")
    defer { cleanup(fixture.path) }
    fixture.state.recordClose(
        decision: .shutdown,
        scope: .always,
        windowID: nil,
        config: fixture.config
    )
    let written = ConfigFile(path: fixture.path)
    #expect(written.value(forKey: CloseDecisions.tabCloseKey) == "shutdown")
    #expect(written.value(forKey: CloseDecisions.quitWithSimsKey) == "shutdown")
}

@MainActor
@Test
func alwaysOnQuitPromptWritesBothKeys() throws {
    let fixture = try makeFixture(contents: "")
    defer { cleanup(fixture.path) }
    fixture.state.recordQuit(decision: .shutdownSims, scope: .always, config: fixture.config)
    let written = ConfigFile(path: fixture.path)
    #expect(written.value(forKey: CloseDecisions.quitWithSimsKey) == "shutdown")
    // shutdownSims → shutdown cross-mapping for the close key.
    #expect(written.value(forKey: CloseDecisions.tabCloseKey) == "shutdown")
}

@MainActor
@Test
func alwaysOnQuitPromptKeepWritesBothKeys() throws {
    let fixture = try makeFixture(contents: "")
    defer { cleanup(fixture.path) }
    fixture.state.recordQuit(decision: .keepSims, scope: .always, config: fixture.config)
    let written = ConfigFile(path: fixture.path)
    #expect(written.value(forKey: CloseDecisions.quitWithSimsKey) == "keep")
    #expect(written.value(forKey: CloseDecisions.tabCloseKey) == "detach")
}

// MARK: - Scope misroutes are no-ops

@MainActor
@Test
func appExitScopeOnClosePromptIsNoOp() throws {
    let fixture = try makeFixture(contents: "")
    defer { cleanup(fixture.path) }
    fixture.state.recordClose(
        decision: .shutdown,
        scope: .appExit,
        windowID: nil,
        config: fixture.config
    )
    #expect(fixture.state.perSession == nil)
    #expect(fixture.state.perWindow.isEmpty)
    #expect(ConfigFile(path: fixture.path).value(forKey: CloseDecisions.tabCloseKey) == nil)
}

@MainActor
@Test
func windowScopeOnQuitPromptIsNoOp() throws {
    let fixture = try makeFixture(contents: "")
    defer { cleanup(fixture.path) }
    fixture.state.recordQuit(decision: .shutdownSims, scope: .window, config: fixture.config)
    #expect(ConfigFile(path: fixture.path).value(forKey: CloseDecisions.quitWithSimsKey) == nil)
}

// MARK: - `.always` evicts softer tiers

@MainActor
@Test
func alwaysEvictsPriorPerWindowAndPerSessionCloseChoices() throws {
    let fixture = try makeFixture(contents: "")
    defer { cleanup(fixture.path) }
    let windowID = WindowID(value: 11)
    // Seed softer tiers with the opposite of what we're about to set
    // permanently, so we can prove the permanent choice wins
    // immediately on the next lookup.
    fixture.state.recordClose(
        decision: .detach,
        scope: .window,
        windowID: windowID,
        config: fixture.config
    )
    fixture.state.recordClose(
        decision: .detach,
        scope: .session,
        windowID: nil,
        config: fixture.config
    )
    fixture.state.recordClose(
        decision: .shutdown,
        scope: .always,
        windowID: nil,
        config: fixture.config
    )
    #expect(fixture.state.perWindow.isEmpty)
    #expect(fixture.state.perSession == nil)
    #expect(
        CloseDecisions.tabClose(
            config: fixture.config,
            state: fixture.state,
            context: CloseContext(windowID: windowID, hasOtherTabsInWindow: true)
        ) == .shutdown
    )
}

@MainActor
@Test
func alwaysOnQuitPromptEvictsPriorCloseTiers() throws {
    let fixture = try makeFixture(contents: "")
    defer { cleanup(fixture.path) }
    fixture.state.recordClose(
        decision: .detach,
        scope: .session,
        windowID: nil,
        config: fixture.config
    )
    fixture.state.recordQuit(
        decision: .shutdownSims,
        scope: .always,
        config: fixture.config
    )
    #expect(fixture.state.perSession == nil)
    // The cross-written `tab-close-default` must now win the next
    // close lookup, with no stale session pick blocking it.
    #expect(
        CloseDecisions.tabClose(
            config: fixture.config,
            state: fixture.state,
            context: CloseContext(windowID: nil, hasOtherTabsInWindow: false)
        ) == .shutdown
    )
}

// MARK: - Fixture helpers

@MainActor
private struct Fixture {
    let path: String
    let config: ConfigFile
    let state: CloseSuppressionState
}

@MainActor
private func makeFixture(contents: String) throws -> Fixture {
    let path = try writeTempConfig(contents: contents)
    return Fixture(path: path, config: ConfigFile(path: path), state: CloseSuppressionState())
}

private func cleanup(_ path: String) {
    try? FileManager.default.removeItem(atPath: path)
}

private func writeTempConfig(contents: String) throws -> String {
    let dir = NSTemporaryDirectory()
    let path = (dir as NSString)
        .appendingPathComponent("deviceterm-close-decisions-\(UUID().uuidString).conf")
    try contents.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}
