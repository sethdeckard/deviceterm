// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Pure decoder that flattens `pane.ax.point`'s
/// opaque-JSON element shape into a one-line summary suitable for the
/// chrome's AX inspector status line. Kept top-level so a unit test
/// can pin the field-priority + empty cases without a daemon
/// connection.
///
/// Shape: the daemon's handler returns `{"element": {...}}` for a hit
/// and `{"element": null}` (decoded as absent) for a miss. The element
/// dict has a flexible vocabulary depending on the underlying AX
/// translation (role / label / identifier / value / …). For the
/// inspector we read role + label + identifier, drop empties, and
/// join with `·`. Full structured introspection is `deviceterm ax tree`'s
/// surface.
enum AxElementSummary {
    /// Parse the daemon's `pane.ax.point` response data. Returns nil
    /// when the daemon reported no element (cursor over chrome / off-
    /// screen / between elements), or when every interesting field
    /// was empty.
    static func parse(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
            let dict = object as? [String: Any] else {
            return nil
        }
        guard let element = dict["element"] as? [String: Any] else { return nil }
        let label = (element["label"] as? String)?
            .trimmingCharacters(in: .whitespaces)
        let role = (element["role"] as? String)?
            .trimmingCharacters(in: .whitespaces)
        let identifier = (element["identifier"] as? String)?
            .trimmingCharacters(in: .whitespaces)
        let parts: [String] = [role, label, identifier].compactMap { candidate in
            guard let value = candidate, !value.isEmpty else { return nil }
            return value
        }
        if parts.isEmpty { return nil }
        return parts.joined(separator: " · ")
    }
}
