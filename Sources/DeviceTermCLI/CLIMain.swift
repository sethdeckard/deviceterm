// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

// deviceterm-cli: short-lived RPC client for the deviceterm daemon.
//
// Symlinked as `deviceterm` into each tab's per-session `bin/`. Speaks
// the canonical `DaemonProtocol` wire: length-prefixed `RPCEnvelope`
// over the daemon's single Unix-domain socket. There is no bespoke
// per-session protocol; every client speaks the same wire.
//
// The CLI surface covers argv parsing, the daemon round-trip, and
// per-verb dispatch; see `DeviceTerm.swift` for the command tree,
// `CLICommands.swift` for the argv rules the tree cannot express, and
// `CommandDispatch.swift` for dispatch. Unary requests go through
// `roundTrip(method:params:)`; `eventsStream` owns its own persistent
// connection and the handshake on it.

/// The process entry point.
///
/// Deliberately not `DeviceTerm.main()`: that renders ArgumentParser's
/// own failure text and exits, which would bypass the CLI's usage block,
/// its exit codes, and the JSON failure envelope a `--json` caller is
/// entitled to even when the invocation never parsed.
///
/// Everything here is a local: a top-level binding in this module reads
/// as its zero value from the test target, which turns assertions that
/// depend on it into ones that pass without testing anything.
@main
enum CLIMain {
    static func main() {
        // Settled before parsing, because a parse failure still has to be
        // able to answer in JSON.
        let output = CLICommands.outputMode(for: CommandLine.arguments)
        let command = CLICommands.parse(CommandLine.arguments)
        var outcome = run(command, transport: UDSTransport(), output: output)
        outcome = outcome.renderingFailure(for: command, output: output)
        if !outcome.stdout.isEmpty { FileHandle.standardOutput.write(outcome.stdout) }
        if let message = outcome.stderr {
            if command.emitsUnprefixedStderr {
                writeStderr(message)
            } else {
                writeStderr("deviceterm: \(message)\n")
            }
        }
        exit(outcome.exitCode)
    }
}
