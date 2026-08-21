// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Foundation
import Testing

// SessionEnvironment generates the per-session ZDOTDIR shell init. These
// tests pin the generated bodies without provisioning a real session dir or
// locating the shim binary (zshDotfileContents is pure).

private func makeEnvironment() -> SessionEnvironment {
    SessionEnvironment(
        sessionId: "11111111-2222-3333-4444-555555555555",
        capability: "cap-token",
        daemonSocketPath: "/tmp/deviceterm-test.sock",
        role: .agent
    )
}

private func zshrc(_ env: SessionEnvironment) throws -> String {
    let body = env.zshDotfileContents().first { $0.name == ".zshrc" }?.body
    return try #require(body)
}

private func zshenv(_ env: SessionEnvironment) throws -> String {
    let body = env.zshDotfileContents().first { $0.name == ".zshenv" }?.body
    return try #require(body)
}

@Test
func sessionCapabilityIsNeverWrittenToDisk() {
    // The capability is not a secret or standalone authority, but generated
    // dotfiles must not persist it unnecessarily. It reaches the terminal
    // through the inherited process environment instead.
    let capability = "cap-token-Xyz123"
    let env = SessionEnvironment(
        sessionId: "11111111-2222-3333-4444-555555555555",
        capability: capability,
        daemonSocketPath: "/tmp/deviceterm-test.sock",
        role: .agent
    )
    for (name, body) in env.zshDotfileContents() {
        #expect(!body.contains(capability), "capability leaked into \(name)")
    }
    // It IS still delivered via the process-environment overlay.
    #expect(env.shellEnvironment()[DeviceTermEnv.sessionCap] == capability)
}

@Test
func reanchorsCompletionDumpToRealHome() throws {
    let env = makeEnvironment()
    let envBody = try zshenv(env)
    // Guarded so an explicit ZSH_COMPDUMP wins; anchored to $HOME with the
    // standard host+version-qualified name so the warm cache is reused.
    #expect(envBody.contains(#"if [[ -z "$ZSH_COMPDUMP" ]]; then"#))
    #expect(envBody.contains(#"export ZSH_COMPDUMP="$HOME/.zcompdump-${_deviceterm_short_host}-${ZSH_VERSION}""#))
    // Never anchored back into the ephemeral session dir.
    #expect(!envBody.contains("ZSH_COMPDUMP=\"\(env.zdotdir)"))
}

@Test
func reanchorsHistFileToRealHomeOutsideTheEphemeralSession() throws {
    let env = makeEnvironment()
    let rc = try zshrc(env)
    // The re-anchor must point HISTFILE at the real home, not the
    // session ZDOTDIR (which is deleted on tab close).
    let home = NSHomeDirectory()
    #expect(rc.contains("export HISTFILE='\(home)'/.zsh_history"))
    // It must not unconditionally clobber a user's own HISTFILE: the
    // guard only fires when HISTFILE is empty or lives in the session dir.
    #expect(rc.contains(#"if [[ -z "$HISTFILE" || "$HISTFILE" == '\#(env.zdotdir)'/* ]]; then"#))
}

@Test
func wrapsSshWithACompatibleRemoteTermFallback() throws {
    let env = makeEnvironment()
    let rc = try zshrc(env)
    #expect(rc.contains(#"function ssh() { TERM=xterm-256color command ssh "$@"; }"#))
    // Guarded so a user's own ssh function/alias is respected.
    #expect(rc.contains("if ! typeset -f ssh >/dev/null 2>&1 && ! alias ssh"))
}

@Test
func sourcesTheUsersRealZshrcBeforeReanchoring() throws {
    let env = makeEnvironment()
    let rc = try zshrc(env)
    let home = NSHomeDirectory()
    let sourceIndex = try #require(rc.range(of: ". '\(home)'/.zshrc"))
    let histIndex = try #require(rc.range(of: "export HISTFILE="))
    // Re-anchor runs after the user's dotfiles so it wins over the
    // /etc/zshrc + oh-my-zsh defaults that leave HISTFILE in ZDOTDIR.
    #expect(sourceIndex.lowerBound < histIndex.lowerBound)
}

@Test
func writesAllFourZshDotfiles() {
    let env = makeEnvironment()
    let names = env.zshDotfileContents().map(\.name).sorted()
    #expect(names == [".zlogin", ".zprofile", ".zshenv", ".zshrc"])
}
