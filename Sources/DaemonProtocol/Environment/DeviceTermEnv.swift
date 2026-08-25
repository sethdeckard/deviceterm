// SPDX-License-Identifier: GPL-3.0-or-later
//
// DeviceTermEnv: the environment-variable names deviceterm injects into a
// terminal pane's shell and reads back across the GUI, daemon, CLI, and shim.
// One source of truth so the writer (SessionEnvironment) and every reader
// can't drift to different spellings.

public enum DeviceTermEnv {
    /// The terminal's session id (set in the shell; read by the CLI + shim).
    public static let session = "DEVICETERM_SESSION"
    /// Capability token authenticating in-tab requests.
    public static let sessionCap = "DEVICETERM_SESSION_CAP"
    /// Daemon Unix-domain socket path.
    public static let daemonSock = "DEVICETERM_DAEMON_SOCK"
    /// Dev override for the daemon binary path.
    public static let daemonPath = "DEVICETERM_DAEMON_PATH"
    /// Per-session `bin/` holding the xcrun/simctl/deviceterm shims.
    public static let shimDir = "DEVICETERM_SHIM_DIR"
    /// Per-terminal GUI relay for DeviceTerm-originated simulator boot claims.
    public static let bootClaimSock = "DEVICETERM_BOOT_CLAIM_SOCK"
    /// zsh `ZDOTDIR` pointing at the session's generated dotfiles.
    public static let zdotdir = "ZDOTDIR"
    /// Default pane target for pane-targeted CLI commands. Set by
    /// `deviceterm with-pane <ref> <cmd…>` to the **resolved canonical
    /// key** (a sim UDID or a physical deviceId) of the chosen pane, so
    /// downstream `deviceterm tap` / `swipe` / etc. inside `<cmd…>`
    /// auto-target it without the agent threading `--pane <ref>`
    /// through every subprocess call. Read by `resolvePane` as the
    /// primary env fallback when `--pane` isn't passed; because it
    /// holds an already-resolved key, the fallback matches it by exact
    /// key (no shortId/name tier shadowing).
    public static let targetPane = "DEVICETERM_TARGET_PANE"
    /// The `SessionRole` (raw string `"agent"` or `"automation"`)
    /// the daemon assigned to the tab's session. Injected by the GUI
    /// at tab open so the agent can introspect cheaply via shell
    /// (`echo $DEVICETERM_SESSION_ROLE`) without an RPC round-trip.
    /// The role is never an authenticator. The daemon authenticates the
    /// connection (cap + kernel terminal provenance), not the role; this env
    /// is for discovery convenience only.
    public static let sessionRole = "DEVICETERM_SESSION_ROLE"

    // MARK: Device-surface pool (daemon-internal tuning + instrumentation)

    /// Device-surface pool slot count, clamped to a documented range.
    public static let surfacePoolSlots = "DEVICETERM_SURFACE_POOL_SLOTS"
    /// Enables off-by-default surface tracing (producer/consumer JSONL).
    public static let surfaceTrace = "DEVICETERM_SURFACE_TRACE"
    /// Adversarial consumer delay (ms) injected in the GUI completion
    /// handler when tracing, to characterize the reuse race.
    public static let surfaceConsumerDelayMs = "DEVICETERM_SURFACE_CONSUMER_DELAY_MS"
    /// Kill switch for per-frame leasing (`0` disables holds/acks/use-count
    /// while keeping the token/drain subscription lifecycle).
    public static let surfaceLeases = "DEVICETERM_SURFACE_LEASES"
    /// Ceiling on the release-ack notification rate per subscription.
    public static let surfaceAckMaxRate = "DEVICETERM_SURFACE_ACK_MAX_RATE"
}
