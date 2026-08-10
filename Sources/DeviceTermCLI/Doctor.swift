// SPDX-License-Identifier: GPL-3.0-or-later
//
// Doctor: pure-logic check primitives + reporters for the
// `deviceterm doctor` command.
//
// `doctor` answers the question agents pivot to when something looks
// broken: "is my context sane?" The checks cover the env vars a
// healthy deviceterm tab carries, the shim's position on PATH, daemon
// reachability + version handshake, the identifier model (sessionId
// + shortId + name + linked panes), and the permissions axes (role
// + allowedMethods) from `daemon.capabilities`.
//
// The check functions stay pure (return a `Check` given inputs) so
// the formatter + status semantics are unit-testable without spawning
// processes. The runner in main.swift gathers I/O (env reads, socket
// connect, daemon ping, tabs.list + panes.list, daemon.capabilities
// and hands the inputs to these primitives. The Report's `ok`
// boolean is derived from `!checks.contains(where: { $0.status ==
// .fail })`; warns don't change exit code (a tab outside the
// deviceterm-managed PATH still works for many commands).
//
// Two distinct axes are reported separately: method availability
// (`role` + `allowedMethods`) and target availability (linked sim
// panes). An agent can have a verb available with zero valid
// targets, and a target can be unreachable even when the verb is
// available. The Permissions section forward-points at `deviceterm
// agents` "PERMISSIONS AND LINKAGE" for the deeper model.

import DaemonProtocol
import Foundation

public enum Doctor {
    public enum Status: String, Sendable, Equatable, Codable {
        case ok
        case warn
        case fail
    }

    public struct Check: Encodable, Sendable, Equatable {
        public let name: String
        public let status: Status
        public let detail: String

        public init(name: String, status: Status, detail: String) {
            self.name = name
            self.status = status
            self.detail = detail
        }
    }

    public struct SessionInfo: Encodable, Sendable, Equatable {
        public let sessionId: String
        public let shortId: String?
        public let name: String?
    }

    public struct Report: Encodable, Sendable {
        public let ok: Bool
        public let checks: [Check]
        public let session: SessionInfo?
        public let targets: [PanesListEntry]?
        /// Role for the caller (descriptive metadata). Nil when daemon
        /// was unreachable or the caller is out-of-tab without creds.
        public let role: SessionRole?
        /// Methods the daemon advertises as callable for this
        /// connection, derived from transport and live grant state,
        /// not from the role. Nil when daemon was unreachable;
        /// populated from `daemon.capabilities.allowedMethods`
        /// otherwise. The method-availability axis (vs. the
        /// target-availability axis carried by `targets`).
        public let allowedMethods: [String]?

        public init(
            checks: [Check],
            session: SessionInfo?,
            targets: [PanesListEntry]?,
            role: SessionRole? = nil,
            allowedMethods: [String]? = nil
        ) {
            self.ok = !checks.contains(where: { $0.status == .fail })
            self.checks = checks
            self.session = session
            self.targets = targets
            self.role = role
            self.allowedMethods = allowedMethods
        }
    }

    // MARK: - Layout constants (shared by formatHuman)

    /// Width of the `[status]` badge column in the human report
    /// (longest status is `[warn]` / `[fail]`, 6 chars). Padding to
    /// 8 keeps the detail column aligned regardless of mix.
    public static let badgeWidth = 8

    /// Width of the check-name column. Long enough for
    /// `DEVICETERM_SESSION_CAP` (19 chars) + the
    /// `xcrun resolves to shim` (22 chars) check label. Padded so
    /// the detail column lands at the same x on every row.
    public static let nameWidth = 24

    // MARK: - Pure checks

    /// `DEVICETERM_SESSION` env var. Unset is `warn` (running outside a
    /// tab is a legitimate use case: daemon health checks); a value
    /// that isn't a UUID is `fail` (env corruption: something
    /// downstream will reject it).
    public static func sessionEnvCheck(value: String?) -> Check {
        guard let value, !value.isEmpty else {
            return Check(
                name: "DEVICETERM_SESSION",
                status: .warn,
                detail: "unset (expected when running outside a deviceterm tab)"
                )
        }
        guard UUID(uuidString: value) != nil else {
            return Check(
                name: "DEVICETERM_SESSION",
                status: .fail,
                detail: "not a UUID: \(value)"
                )
        }
        return Check(name: "DEVICETERM_SESSION", status: .ok, detail: value)
    }

    /// `DEVICETERM_SESSION_CAP`. Only confirms presence + length; the
    /// token is intentionally not printed. It is one authentication
    /// factor rather than the trust anchor (the daemon also matches the
    /// caller's kernel provenance), but diagnostics still don't echo
    /// credentials.
    public static func sessionCapCheck(value: String?) -> Check {
        guard let value, !value.isEmpty else {
            return Check(
                name: "DEVICETERM_SESSION_CAP",
                status: .warn,
                detail: "unset (paired with DEVICETERM_SESSION)"
                )
        }
        return Check(
            name: "DEVICETERM_SESSION_CAP",
            status: .ok,
            detail: "present (\(value.utf8.count) chars)"
            )
    }

    /// Generic env-path check: unset → `warn`, set → `ok` with the
    /// resolved value. Used for `DEVICETERM_DAEMON_SOCK` +
    /// `DEVICETERM_SHIM_DIR` which carry filesystem paths the user may
    /// need to inspect.
    public static func envPathCheck(name: String, value: String?) -> Check {
        guard let value, !value.isEmpty else {
            return Check(name: name, status: .warn, detail: "unset")
        }
        return Check(name: name, status: .ok, detail: value)
    }

    /// `which xcrun` resolution. The shim must be first on PATH for
    /// `xcrun simctl boot` to fire the boot-intercept → pane-attach
    /// path; a system xcrun bypasses deviceterm and creates an
    /// invisible sim. Mismatch is `warn` (the user can still boot
    /// manually via the shim later) with a recovery hint.
    ///
    /// Compares the resolved binary's immediate parent directory
    /// against `shimDir` rather than a hasPrefix check, so a sibling
    /// like `<shimDir>-old/xcrun` doesn't masquerade as the shim.
    public static func xcrunCheck(path: String?, shimDir: String?) -> Check {
        guard let path else {
            return Check(
                name: "xcrun resolves to shim",
                status: .fail,
                detail: "xcrun not found on PATH"
                )
        }
        guard let shimDir, !shimDir.isEmpty else {
            return Check(
                name: "xcrun resolves to shim",
                status: .warn,
                detail: "\(path): DEVICETERM_SHIM_DIR unset; "
                + "shim-intercept boots require the per-session shim on PATH"
                )
        }
        let parentDir = URL(fileURLWithPath: path)
            .deletingLastPathComponent().path
        if parentDir == shimDir {
            return Check(name: "xcrun resolves to shim", status: .ok, detail: path)
        }
        return Check(
            name: "xcrun resolves to shim",
            status: .warn,
            detail: "\(path): shim not first on PATH; "
            + "boots will bypass the deviceterm intercept. Open a fresh tab."
            )
    }

    /// Daemon UDS socket reachability. `fail` if the socket can't be
    /// connected to. Nothing here starts the daemon: the socket is
    /// not a launchd-demand-launched service, and the CLI never
    /// spawns one. So unreachable usually just means no daemon is
    /// running, which is the ordinary state out of tab, and `fail`
    /// reads as "the rest of this report can't be trusted" rather
    /// than "something is wedged."
    public static func socketCheck(path: String, reachable: Bool) -> Check {
        if reachable {
            return Check(name: "Daemon socket", status: .ok, detail: path)
        }
        return Check(
            name: "Daemon socket",
            status: .fail,
            detail: "\(path) not reachable (no daemon running; open DeviceTerm)"
            )
    }

    /// Daemon ping handshake. `fail` on transport / decode errors;
    /// `ok` carries the wire version + daemon pid for the human
    /// report header.
    public static func pingCheck(
        wireVersion: String?,
        pid: Int?,
        error: String?
    ) -> Check {
        if let error {
            return Check(name: "Daemon ping", status: .fail, detail: error)
        }
        let version = wireVersion ?? "?"
        let pidStr = pid.map(String.init) ?? "?"
        return Check(
            name: "Daemon ping",
            status: .ok,
            detail: "wireVersion=\(version) pid=\(pidStr)"
            )
    }

    /// `DEVICETERM_SESSION` env is set but does the daemon agree it's
    /// a live session? After a daemon restart with a stale shell
    /// env, tabs.list won't contain the env's UUID and every
    /// session-scoped call will fail. `fail` here surfaces the
    /// stale-env case before the agent runs an input command and
    /// hits `error.unauthorized`.
    ///
    /// Pure: the runner does tabs.list and passes `foundInTabs`.
    public static func sessionLivenessCheck(
        envSessionId: String,
        foundInTabs: Bool
    ) -> Check {
        if foundInTabs {
            return Check(
                name: "Session live in daemon",
                status: .ok,
                detail: envSessionId
                )
        }
        return Check(
            name: "Session live in daemon",
            status: .fail,
            detail: "\(envSessionId) not in tabs.list "
            + "(daemon may have restarted; open a fresh tab)"
            )
    }

    /// `panes.list` is the first call here that requires a fully
    /// authenticated session: the cap PLUS the caller's kernel terminal
    /// provenance (the cap alone is insufficient; it is readable by any
    /// same-uid process). A `fail` result means the connection didn't
    /// authenticate: a stale/wrong `DEVICETERM_SESSION_CAP`, OR the caller's
    /// terminal doesn't match the session's bound terminal (running outside
    /// the tab). Catching the daemon's rejection here proves the session
    /// authenticates before any input command relies on it.
    public static func panesAuthorizationCheck(error: String?) -> Check {
        if let error {
            return Check(
                name: "Session authenticates (cap + provenance)",
                status: .fail,
                detail: error
                )
        }
        return Check(
            name: "Session authenticates (cap + provenance)",
            status: .ok,
            detail: "panes.list accepted"
            )
    }

    // MARK: - Format

    /// Render the report in human-readable form. Stable layout
    /// (status badge, padded name, detail) so a screen-reader /
    /// agent can parse position too.
    public static func formatHuman(_ report: Report) -> String {
        var lines: [String] = []
        lines.append("deviceterm doctor: environment + daemon diagnostic")
        lines.append("")
        lines.append("Checks")
        for check in report.checks {
            let badge = "[\(check.status.rawValue)]"
                .padding(toLength: badgeWidth, withPad: " ", startingAt: 0)
            let name = check.name
                .padding(toLength: nameWidth, withPad: " ", startingAt: 0)
            lines.append("  \(badge)\(name)\(check.detail)")
        }
        if let session = report.session {
            lines.append("")
            lines.append("Session")
            lines.append("  shortId    \(session.shortId ?? "(missing: older daemon)")")
            lines.append("  name       \(session.name ?? "(unset)")")
            lines.append("  sessionId  \(session.sessionId)")
        }
        if let targets = report.targets {
            lines.append("")
            let suffix = targets.count == 1 ? "" : "s"
            lines.append("Targets (\(targets.count) linked sim pane\(suffix))")
            for target in targets {
                let label = target.shortId ?? target.paneId
                let family = target.family ?? "?"
                lines.append(
                    "  \(label)  "
                    + "udid=\(target.udid)  "
                    + "state=\(target.state.rawValue)  "
                    + "family=\(family)"
                    )
            }
        }
        lines.append("")
        lines.append("Permissions")
        if let role = report.role {
            lines.append("  role             \(role.rawValue)")
        } else {
            lines.append("  role             (daemon unreachable or no session)")
        }
        if let allowedMethods = report.allowedMethods {
            // Method-availability axis: what verbs the caller may
            // invoke. Distinct from target-availability (the
            // `Targets` block above): a method can be allowed yet
            // have zero valid targets (no linked panes yet) and a
            // method can be allowed but rejected at the target level
            // (cross-session pane request). Render as a count + a
            // shortlist so the line stays scannable even with the
            // full daemon registry (~28 methods).
            let preview = allowedMethods.prefix(5).joined(separator: ", ")
            let extra = allowedMethods.count > 5
                ? " (+ \(allowedMethods.count - 5) more)"
                : ""
            lines.append(
                "  allowedMethods   \(allowedMethods.count): \(preview)\(extra)"
            )
        } else {
            lines.append("  allowedMethods   (daemon unreachable)")
        }
        lines.append("  See `deviceterm agents` \"PERMISSIONS AND LINKAGE\" for the model.")
        lines.append("")
        if report.ok {
            lines.append("Result: ok")
        } else {
            let failCount = report.checks.filter { $0.status == .fail }.count
            let suffix = failCount == 1 ? "" : "s"
            lines.append("Result: fail (\(failCount) check\(suffix) failed)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
