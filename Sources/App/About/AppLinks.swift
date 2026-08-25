// SPDX-License-Identifier: GPL-3.0-or-later
//
// AppLinks: the canonical outbound URLs for the app (site, docs, repo,
// releases). Defined once so the About window, help text, and any future
// link surface reference the same values instead of scattering literals.

import Foundation

enum AppLinks {
    // Compile-time-constant, known-valid literals. A malformed one is a
    // programmer error caught on first launch, so the force-unwrap is safe.
    // swiftlint:disable force_unwrapping
    /// Project homepage.
    static let site = URL(string: "https://deviceterm.com")!
    /// User documentation.
    static let docs = URL(string: "https://deviceterm.com/docs")!
    /// Source repository.
    static let gitHub = URL(string: "https://github.com/sethdeckard/deviceterm")!
    /// Releases (signed DMGs).
    static let releases = URL(string: "https://github.com/sethdeckard/deviceterm/releases")!
    /// The full text of deviceterm's own license, linked from the About
    /// window so the program tells users how to view it.
    static let license = URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!
    // swiftlint:enable force_unwrapping

    /// Permalink to a specific source commit, used by the About window to
    /// link the displayed short hash.
    static func commit(_ hash: String) -> URL? {
        URL(string: "https://github.com/sethdeckard/deviceterm/commit/\(hash)")
    }
}
