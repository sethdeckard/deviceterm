// SPDX-License-Identifier: GPL-3.0-or-later
//
// UITestCLI: pure argv parsing for `deviceterm-uitest`.
//
// No I/O: `parse` turns an argument vector into a `UITestCommand`
// (serve the resident, run a client request, or print usage) so the
// parsing surface is unit-testable without a socket. `UITestMain` owns
// the side effects.

import Foundation

/// What the argv resolves to.
enum UITestCommand: Equatable {
    /// Run as the resident harness (binds the socket, serves requests).
    case serve
    /// Connect to the resident and perform one request.
    case client(UITestRequest)
    /// Print help and exit 0.
    case usage
}

struct UITestParseError: Error, Equatable {
    let message: String
}

enum UITestCLI {
    static let usageText = """
    deviceterm-uitest: out-of-process UI-test instrument for deviceterm.

    RESIDENT
      serve                         Run as the resident harness (holds the
                                    Screen Recording + Accessibility grants).
                                    Start it with `make uitest-run`, which
                                    launches the bundled .app via
                                    LaunchServices so the grants attribute to
                                    the harness. Invoking `serve` from a shell
                                    attributes them to your terminal instead.

    CLIENT (talks to the resident over its private socket)
      ping                          Confirm a resident is answering.
      capture window --out <path> [--bundle-id <id>]
                                    Screenshot deviceterm's frontmost window
                                    (main window, or an app-modal alert on
                                    top of it) to a PNG.
      capture status-item --out <path>
                                    Screenshot just the daemon's menu-bar
                                    status item badge to a PNG, or report
                                    it absent (hidden at zero owned sims).
                                    The harness never captures a whole
                                    display; only deviceterm's own windows.
      ax dump [--bundle-id <id>]    Dump deviceterm's AppKit AX tree as JSON.
      drive key <shortcut>          Post a keyboard shortcut (e.g. cmd+t).
      drive click <x> <y> | --ax <label>
                                    Click a window point (normalized 0..1),
                                    or press the accessibility element whose
                                    title/description/identifier equals
                                    <label>, e.g. --ax "Shut Down Sims".
      doctor                        Report resident + TCC-grant health.

    Socket path: $DEVICETERM_UITEST_SOCK, else
      ~/Library/Caches/deviceterm/uitest.sock
    """

    static func parse(_ args: [String]) throws -> UITestCommand {
        guard let verb = args.first else { return .usage }
        let rest = Array(args.dropFirst())

        switch verb {
        case "-h", "--help", "help":
            return .usage

        case "serve":
            return .serve

        case "ping":
            return .client(UITestRequest(method: .ping))

        case "doctor":
            return .client(UITestRequest(method: .doctor))

        case "capture":
            return try parseCapture(rest)

        case "ax":
            return try parseAX(rest)

        case "drive":
            return try parseDrive(rest)

        default:
            throw UITestParseError(message: "unknown command: \(verb)")
        }
    }

    // MARK: - Sub-parsers

    private static func parseCapture(_ args: [String]) throws -> UITestCommand {
        guard let sub = args.first else {
            throw UITestParseError(message: "capture needs a subcommand: window | status-item")
        }
        var flags = Array(args.dropFirst())
        switch sub {
        case "window":
            guard let out = extract("--out", from: &flags) else {
                throw UITestParseError(message: "capture window needs --out <path>")
            }
            var params = ["out": out]
            if let bundleID = extract("--bundle-id", from: &flags) { params["bundleId"] = bundleID }
            try rejectLeftovers(flags, in: "capture window")
            return .client(UITestRequest(method: .captureWindow, params: params))

        case "status-item":
            guard let out = extract("--out", from: &flags) else {
                throw UITestParseError(message: "capture status-item needs --out <path>")
            }
            try rejectLeftovers(flags, in: "capture status-item")
            return .client(UITestRequest(method: .captureStatusItem, params: ["out": out]))

        default:
            throw UITestParseError(message: "unknown capture subcommand: \(sub)")
        }
    }

    private static func parseAX(_ args: [String]) throws -> UITestCommand {
        guard args.first == "dump" else {
            throw UITestParseError(message: "ax needs a subcommand: dump")
        }
        var flags = Array(args.dropFirst())
        var params: [String: String] = [:]
        if let bundleID = extract("--bundle-id", from: &flags) { params["bundleId"] = bundleID }
        try rejectLeftovers(flags, in: "ax dump")
        return .client(UITestRequest(method: .axDump, params: params))
    }

    private static func parseDrive(_ args: [String]) throws -> UITestCommand {
        guard let sub = args.first else {
            throw UITestParseError(message: "drive needs a subcommand: key | click")
        }
        let operands = Array(args.dropFirst())
        switch sub {
        case "key":
            guard operands.count == 1 else {
                throw UITestParseError(message: "drive key needs one <shortcut> (e.g. cmd+t)")
            }
            return .client(UITestRequest(method: .driveKey, params: ["shortcut": operands[0]]))

        case "click":
            var flags = operands
            if let axPath = extract("--ax", from: &flags) {
                try rejectLeftovers(flags, in: "drive click")
                return .client(UITestRequest(method: .driveClick, params: ["ax": axPath]))
            }
            guard flags.count == 2, Double(flags[0]) != nil, Double(flags[1]) != nil else {
                throw UITestParseError(message: "drive click needs <x> <y> (0..1) or --ax <label>")
            }
            return .client(UITestRequest(method: .driveClick, params: ["x": flags[0], "y": flags[1]]))

        default:
            throw UITestParseError(message: "unknown drive subcommand: \(sub)")
        }
    }

    // MARK: - Flag helpers

    /// Remove `--name value` from `args` and return the value, if present.
    private static func extract(_ name: String, from args: inout [String]) -> String? {
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        let value = args[index + 1]
        args.removeSubrange(index...(index + 1))
        return value
    }

    private static func rejectLeftovers(_ args: [String], in context: String) throws {
        guard args.isEmpty else {
            throw UITestParseError(
                message: "unexpected arguments to \(context): \(args.joined(separator: " "))"
            )
        }
    }
}
