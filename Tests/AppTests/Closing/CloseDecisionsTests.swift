// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Foundation
import Testing

// CloseDecisions has three tracks: the sim-disposition prompts
// (`paneClose` / `tabClose` single + bulk / `windowClose`), the quit
// prompt (`quitWithSims`), and the multi-pane confirm
// (`multiPaneTabClose` single + bulk, `multiPaneWindowClose`). Each
// raises a prompt when no stored answer exists, and short-circuits
// when one does exist in `CloseSuppressionState` or
// `~/.config/deviceterm/config`. `paneClose` is the exception: its
// `alwaysAsk` flag forces the prompt regardless of a stored answer,
// so that call can't be reached headlessly.
//
// The short-circuit paths are what these tests pin: it's the
// regression class that lets a user's "Don't ask again" stick, and
// the path that makes the scope tiers (window / session / appExit /
// always) behave as advertised. Every async close-prompt call here
// passes `window: nil`; stored answers must short-circuit before
// presentation. Sheet presentation and target-lifetime dismissal are
// covered by `CloseSheetLifetimeTests`.

// MARK: - Persistent file lookup (forever tier)

@MainActor
@Test
func tabCloseHonorsPersistentDetachDefault() async throws {
    let fixture = try makeFixture(contents: "tab-close-default = detach\n")
    defer { cleanup(fixture.path) }
    #expect(
        await CloseDecisions.tabClose(
            config: fixture.config,
            state: fixture.state,
            context: CloseContext(windowID: nil, hasOtherTabsInWindow: false),
            window: nil
        ) == .detach
    )
}

@MainActor
@Test
func tabCloseHonorsPersistentShutdownDefault() async throws {
    let fixture = try makeFixture(contents: "tab-close-default = shutdown\n")
    defer { cleanup(fixture.path) }
    #expect(
        await CloseDecisions.tabClose(
            config: fixture.config,
            state: fixture.state,
            context: CloseContext(windowID: nil, hasOtherTabsInWindow: false),
            window: nil
        ) == .shutdown
    )
}

@MainActor
@Test
func windowCloseHonorsPersistentDetachDefault() async throws {
    // Window close reuses `tab-close-default` so a single "Don't ask
    // again" applies to both surfaces. Pin the no-prompt path here so
    // the shared key isn't accidentally split into a
    // `window-close-default` regression.
    let fixture = try makeFixture(contents: "tab-close-default = detach\n")
    defer { cleanup(fixture.path) }
    #expect(
        await CloseDecisions.windowClose(
            config: fixture.config,
            state: fixture.state,
            windowID: WindowID(value: 1),
            window: nil
        ) == .detach
    )
}

@MainActor
@Test
func windowCloseHonorsPersistentShutdownDefault() async throws {
    let fixture = try makeFixture(contents: "tab-close-default = shutdown\n")
    defer { cleanup(fixture.path) }
    #expect(
        await CloseDecisions.windowClose(
            config: fixture.config,
            state: fixture.state,
            windowID: WindowID(value: 1),
            window: nil
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

@MainActor
@Test
func paneCloseHonorsPersistentDetachDefault() async throws {
    // Pane close reuses `tab-close-default` too: one question, one stored
    // answer across every surface that asks it. Same regression guard as
    // the window-close pair above, against a `pane-close-default` split.
    let fixture = try makeFixture(contents: "tab-close-default = detach\n")
    defer { cleanup(fixture.path) }
    #expect(
        await CloseDecisions.paneClose(
            config: fixture.config,
            state: fixture.state,
            context: CloseContext(windowID: WindowID(value: 1), hasOtherTabsInWindow: true),
            deviceName: "iPhone 17 Pro",
            window: nil
        ) == .detach
    )
}

@MainActor
@Test
func paneCloseHonorsPersistentShutdownDefault() async throws {
    let fixture = try makeFixture(contents: "tab-close-default = shutdown\n")
    defer { cleanup(fixture.path) }
    #expect(
        await CloseDecisions.paneClose(
            config: fixture.config,
            state: fixture.state,
            context: CloseContext(windowID: WindowID(value: 1), hasOtherTabsInWindow: true),
            deviceName: "iPhone 17 Pro",
            window: nil
        ) == .shutdown
    )
}

// MARK: - Lookup precedence (window > session > persistent)

@MainActor
@Test
func perWindowOverrideBeatsPersistent() async throws {
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
        await CloseDecisions.tabClose(
            config: fixture.config,
            state: fixture.state,
            context: CloseContext(windowID: windowID, hasOtherTabsInWindow: true),
            window: nil
        ) == .detach
    )
    // Different window → falls through to persistent.
    #expect(
        await CloseDecisions.tabClose(
            config: fixture.config,
            state: fixture.state,
            context: CloseContext(
                windowID: WindowID(value: 8),
                hasOtherTabsInWindow: true
            ),
            window: nil
        ) == .shutdown
    )
}

@MainActor
@Test
func paneCloseSharesTheWindowSuppressionTier() async throws {
    // The in-memory tiers are shared too, not only the config file. A
    // "For this window" pick made on a tab close silences the pane prompt
    // in that window. That sharing is the point of reusing the key.
    let fixture = try makeFixture(contents: "tab-close-default = shutdown\n")
    defer { cleanup(fixture.path) }
    let windowID = WindowID(value: 4)
    fixture.state.recordClose(
        decision: .detach,
        scope: .window,
        windowID: windowID,
        config: fixture.config
    )
    #expect(
        await CloseDecisions.paneClose(
            config: fixture.config,
            state: fixture.state,
            context: CloseContext(windowID: windowID, hasOtherTabsInWindow: true),
            deviceName: "iPhone 17 Pro",
            window: nil
        ) == .detach
    )
    // A pane in a different window falls through to the persistent tier.
    #expect(
        await CloseDecisions.paneClose(
            config: fixture.config,
            state: fixture.state,
            context: CloseContext(windowID: WindowID(value: 5), hasOtherTabsInWindow: true),
            deviceName: "iPhone 17 Pro",
            window: nil
        ) == .shutdown
    )
}

@MainActor
@Test
func sessionOverrideBeatsPersistent() async throws {
    let fixture = try makeFixture(contents: "tab-close-default = shutdown\n")
    defer { cleanup(fixture.path) }
    fixture.state.recordClose(
        decision: .detach,
        scope: .session,
        windowID: nil,
        config: fixture.config
    )
    #expect(
        await CloseDecisions.tabClose(
            config: fixture.config,
            state: fixture.state,
            context: CloseContext(windowID: WindowID(value: 1), hasOtherTabsInWindow: false),
            window: nil
        ) == .detach
    )
}

@MainActor
@Test
func perWindowOverrideBeatsSession() async throws {
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
        await CloseDecisions.tabClose(
            config: fixture.config,
            state: fixture.state,
            context: CloseContext(windowID: windowID, hasOtherTabsInWindow: true),
            window: nil
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
func alwaysEvictsPriorPerWindowAndPerSessionCloseChoices() async throws {
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
        await CloseDecisions.tabClose(
            config: fixture.config,
            state: fixture.state,
            context: CloseContext(windowID: windowID, hasOtherTabsInWindow: true),
            window: nil
        ) == .shutdown
    )
}

@MainActor
@Test
func alwaysOnQuitPromptEvictsPriorCloseTiers() async throws {
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
        await CloseDecisions.tabClose(
            config: fixture.config,
            state: fixture.state,
            context: CloseContext(windowID: nil, hasOtherTabsInWindow: false),
            window: nil
        ) == .shutdown
    )
}

// MARK: - Multi-pane confirm: suppression short-circuit + tiers

// The multi-pane confirm prompts through `NSAlert.runModal` like the
// sim prompts, so only its suppressed (no-prompt) paths run headlessly:
// the entry points when a tier says "don't ask", and the record/lookup
// tier behavior itself.

@MainActor
@Test
func multiPaneTabCloseHonorsPersistentCloseValue() async throws {
    let fixture = try makeFixture(contents: "tab-close-multi-pane = close\n")
    defer { cleanup(fixture.path) }
    #expect(
        await CloseDecisions.multiPaneTabClose(
            config: fixture.config,
            state: fixture.state,
            context: CloseContext(windowID: WindowID(value: 1), hasOtherTabsInWindow: true),
            paneCount: 3,
            window: nil
        )
    )
}

@MainActor
@Test
func bulkMultiPaneTabCloseHonorsPersistentCloseValue() async throws {
    let fixture = try makeFixture(contents: "tab-close-multi-pane = close\n")
    defer { cleanup(fixture.path) }
    #expect(
        await CloseDecisions.bulkMultiPaneTabClose(
            config: fixture.config,
            state: fixture.state,
            context: CloseContext(windowID: WindowID(value: 1), hasOtherTabsInWindow: true),
            tabCount: 3,
            multiPaneTabCount: 2,
            window: nil
        )
    )
}

@MainActor
@Test
func multiPaneWindowCloseHonorsPersistentCloseValue() async throws {
    // Window close reuses the same `tab-close-multi-pane` key, mirroring
    // how `windowClose` reuses `tab-close-default`: one stored answer
    // covers every surface that asks the multi-pane question.
    let fixture = try makeFixture(contents: "tab-close-multi-pane = close\n")
    defer { cleanup(fixture.path) }
    #expect(
        await CloseDecisions.multiPaneWindowClose(
            config: fixture.config,
            state: fixture.state,
            windowID: WindowID(value: 1),
            tabCount: 1,
            multiPaneTabCount: 1,
            window: nil
        )
    )
}

@MainActor
@Test
func paneConfirmWindowScopeSuppressesOnlyThatWindow() throws {
    let fixture = try makeFixture(contents: "")
    defer { cleanup(fixture.path) }
    let windowID = WindowID(value: 6)
    fixture.state.recordPaneConfirmSuppression(
        scope: .window,
        windowID: windowID,
        config: fixture.config
    )
    #expect(
        fixture.state.lookupPaneConfirmSuppressed(windowID: windowID, config: fixture.config)
    )
    #expect(
        !fixture.state.lookupPaneConfirmSuppressed(
            windowID: WindowID(value: 7),
            config: fixture.config
        )
    )
    // Nothing persisted.
    #expect(
        ConfigFile(path: fixture.path).value(forKey: CloseDecisions.tabClosePanesKey) == nil
    )
}

@MainActor
@Test
func paneConfirmSessionScopeSuppressesEveryWindow() throws {
    let fixture = try makeFixture(contents: "")
    defer { cleanup(fixture.path) }
    fixture.state.recordPaneConfirmSuppression(
        scope: .session,
        windowID: nil,
        config: fixture.config
    )
    #expect(
        fixture.state.lookupPaneConfirmSuppressed(
            windowID: WindowID(value: 2),
            config: fixture.config
        )
    )
    #expect(fixture.state.lookupPaneConfirmSuppressed(windowID: nil, config: fixture.config))
    #expect(
        ConfigFile(path: fixture.path).value(forKey: CloseDecisions.tabClosePanesKey) == nil
    )
}

@MainActor
@Test
func paneConfirmAlwaysScopePersistsCloseValue() async throws {
    let fixture = try makeFixture(contents: "")
    defer { cleanup(fixture.path) }
    fixture.state.recordPaneConfirmSuppression(
        scope: .always,
        windowID: nil,
        config: fixture.config
    )
    #expect(
        ConfigFile(path: fixture.path).value(forKey: CloseDecisions.tabClosePanesKey) == "close"
    )
    // A fresh state (new app launch) still short-circuits off the file.
    #expect(
        await CloseDecisions.multiPaneTabClose(
            config: ConfigFile(path: fixture.path),
            state: CloseSuppressionState(),
            context: CloseContext(windowID: nil, hasOtherTabsInWindow: false),
            paneCount: 2,
            window: nil
        )
    )
}

@MainActor
@Test
func paneConfirmAppExitScopeIsNoOp() throws {
    let fixture = try makeFixture(contents: "")
    defer { cleanup(fixture.path) }
    fixture.state.recordPaneConfirmSuppression(
        scope: .appExit,
        windowID: nil,
        config: fixture.config
    )
    #expect(!fixture.state.lookupPaneConfirmSuppressed(windowID: nil, config: fixture.config))
    #expect(
        ConfigFile(path: fixture.path).value(forKey: CloseDecisions.tabClosePanesKey) == nil
    )
}

@MainActor
@Test
func paneConfirmExplicitAskIsNotSuppressed() throws {
    let fixture = try makeFixture(contents: "tab-close-multi-pane = ask\n")
    defer { cleanup(fixture.path) }
    #expect(!fixture.state.lookupPaneConfirmSuppressed(windowID: nil, config: fixture.config))
}

// MARK: - The two tracks never cross-write

@MainActor
@Test
func paneConfirmAlwaysDoesNotTouchSimKeys() throws {
    let fixture = try makeFixture(contents: "")
    defer { cleanup(fixture.path) }
    fixture.state.recordPaneConfirmSuppression(
        scope: .always,
        windowID: nil,
        config: fixture.config
    )
    let written = ConfigFile(path: fixture.path)
    #expect(written.value(forKey: CloseDecisions.tabCloseKey) == nil)
    #expect(written.value(forKey: CloseDecisions.quitWithSimsKey) == nil)
}

@MainActor
@Test
func simTrackAlwaysDoesNotTouchPaneConfirmKey() throws {
    let fixture = try makeFixture(contents: "")
    defer { cleanup(fixture.path) }
    fixture.state.recordClose(
        decision: .shutdown,
        scope: .always,
        windowID: nil,
        config: fixture.config
    )
    fixture.state.recordQuit(decision: .keepSims, scope: .always, config: fixture.config)
    #expect(
        ConfigFile(path: fixture.path).value(forKey: CloseDecisions.tabClosePanesKey) == nil
    )
    #expect(!fixture.state.lookupPaneConfirmSuppressed(windowID: nil, config: fixture.config))
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
