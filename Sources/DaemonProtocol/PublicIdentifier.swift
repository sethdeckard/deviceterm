// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Lowercase UUID formatting for the identifiers DeviceTerm publishes, with
/// any string that is not a UUID preserved exactly.
///
/// One definition makes the spelling a single decision rather than a convention
/// each transport boundary has to remember.
///
/// Not a `UUID` extension: half the need is on the ingest side, where the
/// caller holds a `String` it received and wants it in canonical form, and an
/// extension on `UUID` can only serve the render half.
public enum PublicIdentifier {
    /// Render `id` as DeviceTerm publishes it.
    public static func string(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }

    /// Put a received identifier into the published form, leaving anything
    /// that is not a UUID exactly as given.
    ///
    /// The passthrough is the point, not a fallback. Physical CoreDevice ids
    /// (`00008130-001C195E0E91802E`) are not UUID-shaped and belong to
    /// `devicectl`, and the GUI mints `"failed-<uuid>"` placeholders for a tab
    /// whose terminal never came up. Both have to survive a trip through here
    /// byte for byte.
    ///
    /// Surrounding whitespace is trimmed before parsing, so a ref pasted with a
    /// trailing newline canonicalizes rather than passing through untouched.
    public static func canonicalized(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = UUID(uuidString: trimmed) else { return raw }
        return string(parsed)
    }
}
