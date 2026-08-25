// SPDX-License-Identifier: GPL-3.0-or-later
//
// ShellLocale: derive a POSIX `LANG` for the spawned login shell.
//
// A GUI `.app` launched via Finder/LaunchServices inherits no `LANG`, so a
// shell it spawns starts with an unset locale: `setlocale` warnings from
// perl / git hooks / man, non-ASCII filenames printed as octal escapes,
// and locale-dependent `sort` / `date` / `wc -m` misbehaving. Terminal.app,
// iTerm, and Ghostty all derive a UTF-8 `LANG` from the system region and
// export it to the child shell; this mirrors that.
//
// Pure + injectable so the derivation is unit-tested without touching the
// real `Locale` / process environment.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum ShellLocale {
    /// Whether the C library can actually load `name` as a locale. Uses
    /// `newlocale` (not `setlocale`) so the probe never mutates the
    /// process-global locale and is safe to call off the C-locale path;
    /// names that aren't in `locale -a` return false with no side effects.
    static func isInstalled(_ name: String) -> Bool {
        // <xlocale.h>'s LC_ALL_MASK is a composite macro Swift can't
        // import; reconstruct it from the per-category masks (each a
        // simple bit, importable on its own).
        let allMask = LC_COLLATE_MASK | LC_CTYPE_MASK | LC_MESSAGES_MASK
            | LC_MONETARY_MASK | LC_NUMERIC_MASK | LC_TIME_MASK
        guard let loc = newlocale(allMask, name, nil) else { return false }
        freelocale(loc)
        return true
    }

    /// A valid POSIX UTF-8 `LANG`. Prefers `language_REGION.UTF-8` when
    /// that locale is actually installed; otherwise falls back to
    /// `en_US.UTF-8` (always present on macOS) so we never hand the shell
    /// a name `setlocale` rejects, which would reproduce the very
    /// warnings this is meant to fix. The classic miss is an English UI
    /// with a non-English region (e.g. `en_DE`), which macOS doesn't ship.
    static func posixLang(
        language: String?,
        region: String?,
        isInstalled: (String) -> Bool = isInstalled
    ) -> String {
        if let language, !language.isEmpty, let region, !region.isEmpty {
            let candidate = "\(language)_\(region).UTF-8"
            if isInstalled(candidate) { return candidate }
        }
        return "en_US.UTF-8"
    }

    /// The `LANG` to inject into the shell env, or `nil` when the process
    /// already carries one (the spawned shell inherits it, so don't override
    /// a locale the user set deliberately). Only an empty/absent `existing`
    /// triggers a derived value.
    static func injectedLang(
        existing: String?,
        language: String? = Locale.current.language.languageCode?.identifier,
        region: String? = Locale.current.region?.identifier,
        isInstalled: (String) -> Bool = isInstalled
    ) -> String? {
        guard existing?.isEmpty ?? true else { return nil }
        return posixLang(language: language, region: region, isInstalled: isInstalled)
    }
}
