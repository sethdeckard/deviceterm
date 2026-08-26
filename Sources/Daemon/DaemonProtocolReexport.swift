// SPDX-License-Identifier: GPL-3.0-or-later

@_exported import DaemonProtocol

// The single intentional umbrella re-export.
//
// The wire layer (`RPCFraming`, `RPCEnvelope` + `RPCError`, `RPCAck`) lives
// in the Foundation-only `DaemonProtocol` module so the GUI client and
// `deviceterm-cli` can share it without pulling `CoreSimulatorBridge`.
//
// `@_exported` exposes those public types through `Daemon`, so a consumer
// needs only `import Daemon` to reach them. Swift does not re-export by
// default; this one line is the deliberate strategy.
//
// Note: this re-export is for *clients* of `Daemon`. Other files *within*
// the `Daemon` module still take their own per-file `import DaemonProtocol`.
