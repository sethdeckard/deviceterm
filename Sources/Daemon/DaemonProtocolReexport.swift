// SPDX-License-Identifier: GPL-3.0-or-later
//
// DaemonProtocolReexport: the single intentional umbrella re-export.
//
// The wire layer (`RPCFraming`, `RPCEnvelope` + `RPCError`,
// `RPCAck`) lives in the Foundation-only `DaemonProtocol` module so
// the GUI client and `deviceterm-cli` can share it without pulling
// `CoreSimulatorBridge`.
//
// `@_exported` makes those public types part of `Daemon`'s interface
// again, so every existing `import Daemon` / `@testable import Daemon`
// consumer (the 23 DaemonTests files, `DeviceTermDaemon`) keeps compiling
// with zero source edits, since the relocation is behaviour-identical and
// the unchanged green test suite is the proof. Swift does not
// re-export by default; this one line is the deliberate strategy.
//
// Note: this re-export is for *clients* of `Daemon`. Other files
// *within* the `Daemon` module still take their own per-file
// `import DaemonProtocol`.

@_exported import DaemonProtocol
