// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The shell + environment a TerminalSurface spawns.
///
/// libghostty owns the PTY: it `posix_spawn`s the child itself from the
/// `command` / `env_vars` / `working_directory` it's handed in
/// `ghostty_surface_config_s`. There is no byte-stream-in API. So the
/// host doesn't forward PTY bytes; it describes *what to run*, and the
/// surface owns the process for its lifetime. This value type is that
/// description, kept in a libghostty-free module so `App` can depend on
/// the contract without pulling the C framework.
///
/// In deviceterm the daemon issues the session credentials
/// (`DEVICETERM_SESSION`, `DEVICETERM_SESSION_CAP`) at `session.create`;
/// the GUI assembles them with the values it owns (`DEVICETERM_DAEMON_SOCK`,
/// `DEVICETERM_SHIM_DIR`, the ZDOTDIR/PATH overrides) and merges the whole
/// set into `environment` here before attaching. The shim and CLI inside
/// the shell use that environment to reach the daemon.
public struct TerminalCommand: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String?
    /// Bytes fed into the surface as if the user typed them, after the
    /// shell is up. Maps to libghostty's `config.initial_input`. Use
    /// for `deviceterm tab open --cmd 'foo'`-style startup commands so the
    /// command runs once and the user stays at an interactive prompt
    /// (rather than `executable = "$SHELL -c foo"` semantics, which
    /// would exit the pane the moment `foo` returns).
    public var initialInput: String?

    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: String? = nil,
        initialInput: String? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.initialInput = initialInput
    }

    /// A login shell: `$SHELL -l`, falling back to `/bin/zsh` when
    /// `SHELL` is unset. Both the harness and the GUI's terminal pane
    /// need exactly this; resolving it once avoids two copies of the
    /// fallback rule drifting apart.
    public static func loginShell(
        environment: [String: String] = [:],
        workingDirectory: String? = nil,
        initialInput: String? = nil
    ) -> TerminalCommand {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return TerminalCommand(
            executable: shell,
            arguments: ["-l"],
            environment: environment,
            workingDirectory: workingDirectory,
            initialInput: initialInput
        )
    }
}
