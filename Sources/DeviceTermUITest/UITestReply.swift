// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

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
