// SPDX-License-Identifier: GPL-3.0-or-later
//
// UITestProtocol: the request/reply vocabulary the UI-test harness
// vends over its own private Unix-domain socket.
//
// Deliberately separate from `DaemonProtocol.RPCMethod`: the harness is
// a test *instrument* that screenshots and drives deviceterm from the
// outside, not a deviceterm RPC peer. Its method set stays decoupled
// from the daemon's wire contract. The only thing borrowed from
// `DaemonProtocol` is the length-prefixed framing (`RPCFraming`) and the
// client socket primitive (`UDSClientSocket`), both Foundation-only.

import Foundation

/// The methods a client may ask the resident harness to perform.
///
/// Raw values are the on-the-wire method names.
public enum UITestMethod: String, Codable, Sendable, CaseIterable, Equatable {
    /// Liveness probe: confirms a resident harness is answering.
    case ping
    /// Screenshot a specific deviceterm window (composited pixels) → PNG.
    /// Never a whole display: the harness only ever captures the app under
    /// test's own windows, so it can't screenshot unrelated apps.
    case captureWindow = "capture.window"
    /// Screenshot just the daemon's menu-bar status item window → PNG, or
    /// report it absent (which is how "hidden at zero owned sims" reads).
    case captureStatusItem = "capture.status-item"
    /// Walk an app's AppKit accessibility tree → JSON.
    case axDump = "ax.dump"
    /// Post a keyboard shortcut (a GUI-only gesture with no CLI path).
    case driveKey = "drive.key"
    /// Click at a point or on an AX element.
    case driveClick = "drive.click"
    /// Report resident + TCC-grant health (client-side check + probe).
    case doctor
}

/// One request frame: a method plus a flat string-keyed parameter bag.
///
/// Every scalar the harness needs (paths, bundle ids, coordinates,
/// shortcuts) serializes as a string; the responder parses per method.
/// A flat `[String: String]` keeps the wire shape trivial and the
/// Codable synthesis dependency-free.
public struct UITestRequest: Codable, Sendable, Equatable {
    public let method: UITestMethod
    public var params: [String: String]

    public init(method: UITestMethod, params: [String: String] = [:]) {
        self.method = method
        self.params = params
    }
}

/// Builders for the JSON reply the resident frames back to the client.
///
/// Replies are plain JSON objects (not a Codable struct) so a method
/// can vend arbitrary structured payloads (`ax.dump`'s recursive tree,
/// for one) without a bespoke type per method. Every reply carries a
/// boolean `ok`; the client keys its exit code off it. Keys are sorted
/// so output is stable and diffable.
public enum UITestReply {
    /// A success reply: `{"ok":true, …fields}`.
    public static func ok(_ fields: [String: Any] = [:]) -> Data {
        var object: [String: Any] = ["ok": true]
        for (key, value) in fields { object[key] = value }
        return serialize(object)
    }

    /// A failure reply: `{"ok":false,"error":message}`.
    public static func failure(_ message: String) -> Data {
        serialize(["ok": false, "error": message])
    }

    /// A reply whose `ok` is computed rather than assumed: `doctor`,
    /// where the fields carry the diagnosis and `ok` merely summarizes
    /// whether the harness is usable.
    public static func result(ok isOK: Bool, _ fields: [String: Any]) -> Data {
        var object: [String: Any] = ["ok": isOK]
        for (key, value) in fields { object[key] = value }
        return serialize(object)
    }

    private static func serialize(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data(#"{"ok":false,"error":"reply serialization failed"}"#.utf8)
    }
}
