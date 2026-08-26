// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The per-terminal-session directory and shell environment.
///
/// The GUI process (libghostty) spawns the terminal's shell, so the GUI
/// (not the daemon) owns the per-session scratch dir and the env
/// injected into that shell. It also owns the terminal-bound boot-claim relay
/// that lets the shim hand a boot attempt to the GUI without waiting for the
/// daemon. The session UUID and capability come from `session.create`; the
/// daemon remains the session registry. `owner.pid` is the GUI pid, which is
/// the liveness marker used by cold-start orphan recovery.
///
/// The injected env must carry `DEVICETERM_DAEMON_SOCK` (the global
/// daemon socket: the daemon and shim both read this name) and
/// `DEVICETERM_SESSION_CAP` for daemon authentication and
/// `DEVICETERM_BOOT_CLAIM_SOCK` for boot-attribution handoff.
final class SessionEnvironment {
    let sessionId: String
    let capability: String
    let daemonSocketPath: String
    /// Role assigned to this session (descriptive metadata, not an
    /// authorization gate). Injected into the shell as
    /// `DEVICETERM_SESSION_ROLE` so the agent can introspect cheaply via
    /// `echo $DEVICETERM_SESSION_ROLE` without an RPC round-trip. The
    /// daemon authenticates the connection (cap + kernel terminal provenance),
    /// never the role, on every session-scoped call; this env is for
    /// discovery convenience, not authentication.
    let role: SessionRole
    let sessionDir: String
    let binDir: String
    let zdotdir: String
    private var ownedUDIDs: Set<String> = []
    private let bootClaimRelay: BootClaimRelay
    /// Path the orphan-recovery sweep looks for. `{sessionId,
    /// ownerPid, udids}`: `sessionId` is redundant with the dir
    /// name but makes the file self-describing; `ownerPid` is the
    /// liveness sentinel (also lives in `owner.pid`); `udids` are
    /// the sims this session has attached.
    var manifestPath: String {
        (sessionDir as NSString).appendingPathComponent("owned-udids.json")
    }

    init(
        sessionId: String,
        capability: String,
        daemonSocketPath: String,
        role: SessionRole = .agent,
        onBootClaim: @escaping BootClaimRelay.Handler = { _, _, _ in }
    ) {
        self.sessionId = sessionId
        self.capability = capability
        self.role = role
        self.daemonSocketPath = daemonSocketPath
        self.bootClaimRelay = BootClaimRelay(sessionId: sessionId, handler: onBootClaim)
        let cache = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Caches/deviceterm/sessions")
        self.sessionDir = (cache as NSString).appendingPathComponent(sessionId)
        self.binDir = (sessionDir as NSString).appendingPathComponent("bin")
        self.zdotdir = (sessionDir as NSString).appendingPathComponent("zsh")
    }

    // MARK: - Sibling location / orphan sweep

    /// Locate a sibling executable next to the running binary (the
    /// `.app`'s `Contents/Helpers/` or `.build/<cfg>/` in dev).
    static func locateSibling(named name: String) -> String? {
        var bufSize = UInt32(4_096)
        var buf = [CChar](repeating: 0, count: Int(bufSize))
        guard _NSGetExecutablePath(&buf, &bufSize) == 0 else { return nil }
        // `buf` stays `[CChar]` for `_NSGetExecutablePath`; read it back
        // through the raw bytes so the decode sees `UInt8` without a copy.
        guard let exe = buf.withUnsafeBytes({
            String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8)
        }) else { return nil }
        let dir = (exe as NSString).deletingLastPathComponent
        // Dev: siblings live next to the exe. Bundled: the GUI exe is
        // in Contents/MacOS; helpers are in Contents/Helpers.
        let candidates = [
            (dir as NSString).appendingPathComponent(name),
            ((dir as NSString).deletingLastPathComponent as NSString)
                .appendingPathComponent("Helpers/\(name)")
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Delete session dirs whose `owner.pid` names a dead process.
    /// Best-effort; called at GUI startup.
    static func cleanupOrphans() {
        let cache = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Caches/deviceterm/sessions")
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: cache) else {
            return
        }
        for entry in entries {
            let dir = (cache as NSString).appendingPathComponent(entry)
            let marker = (dir as NSString).appendingPathComponent("owner.pid")
            var alive = false
            if let pidStr = try? String(contentsOfFile: marker, encoding: .utf8),
                let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)),
                kill(pid, 0) == 0 {
                alive = true
            }
            if !alive { try? fileManager.removeItem(atPath: dir) }
        }
    }

    /// Remove a session's scratch dir by id (no instance needed). The
    /// Router calls this on closeTab/closeWindow with `.shutdown` since
    /// it doesn't hold the terminal's SessionEnvironment.
    static func cleanup(sessionId: String) {
        let dir = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Caches/deviceterm/sessions/\(sessionId)")
        try? FileManager.default.removeItem(atPath: dir)
    }

    // MARK: - Lifecycle

    /// Create the session dir, install shim/CLI symlinks, write the
    /// zsh dotfiles, and stamp `owner.pid`. Throws if the dir can't be
    /// created or the shim binary can't be located.
    func provision() throws {
        try setupSessionDir()
        try installShimSymlinks()
        try writeZshDotfiles()
        try bootClaimRelay.start()
        let markerPath = (sessionDir as NSString).appendingPathComponent("owner.pid")
        try? "\(getpid())\n".write(toFile: markerPath, atomically: true, encoding: .utf8)
    }

    /// Remove this session's scratch dir. Called on tab/app teardown.
    func cleanup() {
        bootClaimRelay.stop()
        try? FileManager.default.removeItem(atPath: sessionDir)
    }

    /// Stop accepting claims when the terminal pane is gone while preserving
    /// its directory for detach/orphan recovery.
    func stopBootClaimRelay() {
        bootClaimRelay.stop()
    }

    /// Bind the local relay to the same kernel-derived terminal facts used by
    /// daemon authentication. Until this succeeds, the relay answers notReady.
    func bindBootClaimRelay(foregroundPid: pid_t, ttyName: String) {
        bootClaimRelay.bind(foregroundPid: foregroundPid, ttyName: ttyName)
    }

    /// Record that this session has attached `udid` and persist the
    /// updated manifest atomically.
    func recordOwnership(_ udid: String) {
        ownedUDIDs.insert(udid)
        writeManifest()
    }

    /// Mirror of `recordOwnership` for detach.
    func releaseOwnership(_ udid: String) {
        ownedUDIDs.remove(udid)
        writeManifest()
    }

    /// The env merged into the tab shell's `TerminalCommand`.
    /// libghostty overlays these onto the inherited process env, so
    /// they apply to *any* login shell. PATH is prepended here (not
    /// only in the zsh dotfiles) because the ZDOTDIR files are ignored
    /// by bash/fish/etc. Without this, non-zsh users would resolve
    /// the real xcrun/simctl instead of the session shim and lose
    /// boot detection + provenance. The zsh precmd hook still
    /// re-prepends every prompt as defense against dotfiles that
    /// recompute PATH mid-session.
    func shellEnvironment() -> [String: String] {
        let basePath = ProcessInfo.processInfo.environment["PATH"]
            ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return [
            DeviceTermEnv.session: sessionId,
            DeviceTermEnv.sessionCap: capability,
            DeviceTermEnv.sessionRole: role.rawValue,
            DeviceTermEnv.daemonSock: daemonSocketPath,
            DeviceTermEnv.shimDir: binDir,
            DeviceTermEnv.bootClaimSock: bootClaimRelay.socketPath,
            DeviceTermEnv.zdotdir: zdotdir,
            "PATH": "\(binDir):\(basePath)"
        ]
    }

    // MARK: - Setup

    private func setupSessionDir() throws {
        let fileManager = FileManager.default
        do {
            for dir in [sessionDir, binDir, zdotdir] {
                try fileManager.createDirectory(
                    atPath: dir,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
        } catch {
            throw SessionEnvironmentError.directorySetupFailed(error.localizedDescription)
        }
    }

    private func installShimSymlinks() throws {
        guard let shimSource = Self.locateSibling(named: "deviceterm-shim") else {
            throw SessionEnvironmentError.shimBinaryNotFound
        }
        let fileManager = FileManager.default
        for name in ["xcrun", "simctl"] {
            let dest = (binDir as NSString).appendingPathComponent(name)
            try? fileManager.removeItem(atPath: dest)
            try fileManager.createSymbolicLink(atPath: dest, withDestinationPath: shimSource)
        }
        // deviceterm CLI is optional: if it isn't built alongside, the
        // pane just won't have `deviceterm` on PATH.
        if let cliSource = Self.locateSibling(named: "deviceterm-cli") {
            let dest = (binDir as NSString).appendingPathComponent("deviceterm")
            try? fileManager.removeItem(atPath: dest)
            try fileManager.createSymbolicLink(atPath: dest, withDestinationPath: cliSource)
        }
    }

    /// ZDOTDIR dotfiles: source the user's real dotfiles, re-export
    /// the deviceterm env, then strip-and-prepend the shim dir to PATH on
    /// every prompt (robust against user dotfiles recomputing PATH).
    private func writeZshDotfiles() throws {
        for (name, body) in zshDotfileContents() {
            let path = (zdotdir as NSString).appendingPathComponent(name)
            try body.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// The `(filename, body)` pairs written into ZDOTDIR. Pure (no I/O)
    /// so the generated shell init is unit-testable without provisioning
    /// a real session dir or locating the shim binary.
    func zshDotfileContents() -> [(name: String, body: String)] {
        let userHome = NSHomeDirectory()
        // The session CAPABILITY is deliberately NOT written here. It reaches
        // the shell only through the inherited process environment
        // (`shellEnvironment()` → libghostty overlay). This is NOT because env
        // is unreadable: a same-uid process CAN read another process's env
        // (`ps -E`), which is exactly why the cap is only one factor and the
        // daemon also checks kernel terminal provenance. The point is
        // persistence: a dotfile on disk lives indefinitely and is readable
        // any time by every same-uid process, whereas the env copy is
        // transient (gone when the process exits) and a caller
        // that pastes a stolen cap still can't match the session's bound
        // terminal. Non-secret vars stay here so non-zsh shells still get them.
        let header = """
        # deviceterm session-managed zsh init. Do not edit; regenerated per session.
        export \(DeviceTermEnv.session)=\(esc(sessionId))
        export \(DeviceTermEnv.daemonSock)=\(esc(daemonSocketPath))
        export \(DeviceTermEnv.shimDir)=\(esc(binDir))

        """
        let prependShim = """
        if [ -n "$\(DeviceTermEnv.shimDir)" ]; then
          path=("${(@)path:#$\(DeviceTermEnv.shimDir)}")
          path=("$\(DeviceTermEnv.shimDir)" $path)
          export PATH
        fi
        """
        // macOS /etc/zshrc derives HISTFILE from ${ZDOTDIR:-$HOME}, and
        // deviceterm points ZDOTDIR at a per-session dir that is removed when
        // the tab closes. Left as-is, every tab writes its history into
        // that throwaway dir and loses it on close (recall works in-session
        // because it's the same file, then it's gone). Re-anchor to the
        // real home history file, unless the user set an explicit HISTFILE
        // of their own outside the session dir, which we leave intact.
        let reanchorHistFile = """
        if [[ -z "$HISTFILE" || "$HISTFILE" == \(esc(zdotdir))/* ]]; then
          export HISTFILE=\(esc(userHome))/.zsh_history
        fi
        """
        // Same ${ZDOTDIR:-$HOME} trap as HISTFILE, one layer up: macOS
        // /etc/zshrc and frameworks (oh-my-zsh) derive the completion-dump
        // cache path from ZDOTDIR, so with it pointed at the per-session
        // dir the cache is written there and deleted on tab close. Every
        // new tab then pays a full compinit rebuild. Preset ZSH_COMPDUMP to
        // the real home using the standard host+version-qualified name
        // (oh-my-zsh honors an existing value), so the cache persists and a
        // warm one is reused. Set in .zshenv so it lands before the .zshrc
        // phase where frameworks read it. Plain compinit ignores this var,
        // but its rebuild is cheap.
        let reanchorCompdump = """
        if [[ -z "$ZSH_COMPDUMP" ]]; then
          if [[ "$OSTYPE" = darwin* ]]; then
            _deviceterm_short_host=$(scutil --get LocalHostName 2>/dev/null) || _deviceterm_short_host="${HOST/.*/}"
          else
            _deviceterm_short_host="${HOST/.*/}"
          fi
          export ZSH_COMPDUMP="$HOME/.zcompdump-${_deviceterm_short_host}-${ZSH_VERSION}"
          unset _deviceterm_short_host
        fi
        """
        let envFile = """
        \(header)
        [ -r \(esc(userHome))/.zshenv ] && . \(esc(userHome))/.zshenv

        \(reanchorCompdump)

        \(prependShim)
        """
        // xterm-ghostty terminfo is absent on most remote hosts, so ncurses
        // apps (vim, htop, less) garble over ssh. Wrap ssh to hand the
        // remote a universally-known TERM: the same fallback Ghostty's
        // ssh-env shell-integration feature gives. (Ghostty's richer
        // ssh-terminfo half, which installs xterm-ghostty on the remote,
        // needs a ghostty CLI deviceterm doesn't ship, so we mirror just the
        // env fallback.) Local sessions keep full xterm-ghostty; the guard
        // leaves a user's own ssh function/alias untouched.
        let sshTermFallback = """
        if ! typeset -f ssh >/dev/null 2>&1 && ! alias ssh >/dev/null 2>&1; then
          function ssh() { TERM=xterm-256color command ssh "$@"; }
        fi
        """
        let rcFile = """
        \(header)
        [ -r \(esc(userHome))/.zshrc ] && . \(esc(userHome))/.zshrc

        \(reanchorHistFile)

        \(sshTermFallback)

        # Strip-and-prepend on every prompt; robust against dotfile/tool PATH edits.
        autoload -Uz add-zsh-hook 2>/dev/null && {
          _deviceterm_path() {
            \(prependShim.replacingOccurrences(of: "\n", with: "\n    "))
          }
          add-zsh-hook precmd _deviceterm_path
          _deviceterm_path
        }
        """
        let profileFile = """
        \(header)
        [ -r \(esc(userHome))/.zprofile ] && . \(esc(userHome))/.zprofile
        \(prependShim)
        """
        let loginFile = """
        \(header)
        [ -r \(esc(userHome))/.zlogin ] && . \(esc(userHome))/.zlogin
        """
        return [
            (".zshenv", envFile),
            (".zshrc", rcFile),
            (".zprofile", profileFile),
            (".zlogin", loginFile)
        ]
    }

    private func esc(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func writeManifest() {
        let body: [String: Any] = [
            "sessionId": sessionId,
            "ownerPid": Int(getpid()),
            "udids": ownedUDIDs.sorted()
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: body,
            options: [.sortedKeys]
        ) else { return }
        // `Data.write(.atomic)` writes to a sibling temp and renames,
        // which both creates and replaces. `replaceItemAt` would
        // fail on the very first write (no original to replace),
        // which is exactly when orphan recovery needs the manifest
        // to start existing.
        try? data.write(
            to: URL(fileURLWithPath: manifestPath),
            options: .atomic
        )
    }
}
