// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The static facts shown in the About window, resolved from
/// the app bundle's Info.plist. Pure value; read once when the window opens.
/// Each field degrades to a sensible placeholder when the key is absent
/// (e.g. a raw `swift run` with no assembled `.app`), so the window never
/// shows an empty row.
struct AboutInfo: Equatable {
    /// The README subtitle, shown under the app name.
    static let defaultTagline =
        "A macOS-native terminal that runs live iOS Simulators as panes beside your shell."
    /// Used when `NSHumanReadableCopyright` is absent, which happens on a
    /// raw `swift run` with no assembled `.app`.
    static let defaultCopyright = "© 2026 Seth Deckard"

    let name: String
    let tagline: String
    let version: String
    let build: String
    /// Short git hash baked in at bundle time (`DTSourceCommit`); `nil`
    /// for non-bundled dev runs, in which case the commit row is hidden.
    let commit: String?
    /// Copyright line from `NSHumanReadableCopyright`. Shown with the
    /// license notice the GPL asks an interactive program to display.
    let copyright: String

    static func current(
        bundle: Bundle = .main,
        tagline: String = defaultTagline
    ) -> AboutInfo {
        resolve(info: bundle.infoDictionary ?? [:], tagline: tagline)
    }

    /// Pure resolution from an Info.plist dictionary, the testable core of
    /// `current`. Empty strings and the `"unknown"` bundle-time commit
    /// fallback are treated as absent so no row shows a placeholder value.
    static func resolve(info: [String: Any], tagline: String = defaultTagline) -> AboutInfo {
        func string(_ key: String) -> String? {
            (info[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        return AboutInfo(
            name: string("CFBundleName") ?? "DeviceTerm",
            tagline: tagline,
            version: string("CFBundleShortVersionString") ?? "—",
            build: string("CFBundleVersion") ?? "—",
            commit: string("DTSourceCommit").flatMap { $0 == "unknown" ? nil : $0 },
            copyright: string("NSHumanReadableCopyright") ?? defaultCopyright
        )
    }
}
