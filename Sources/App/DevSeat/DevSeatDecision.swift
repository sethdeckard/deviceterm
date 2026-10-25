// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Whether this app is the dev seat's debug build, the only one that answers
/// pane snapshot requests.
///
/// The seat is the checkout the user blessed with `make bless`
/// (`scripts/dev-seat.sh`), recorded as the first line of the holder file in
/// the seat directory. This app is the seat's when its executable sits under
/// that checkout's `.build/debug/`, so an installed app, a release bundle,
/// and every other checkout's build all answer no.
enum DevSeatDecision {
    /// The seat directory, beside the track locks.
    static var seatDirectory: String { "/tmp/deviceterm.\(getuid()).seat" }

    /// The blessed checkout root in `seatDirectory`'s holder file, or nil
    /// when no checkout holds the seat.
    static func holderRoot(seatDirectory: String = seatDirectory) -> String? {
        let holder = (seatDirectory as NSString).appendingPathComponent("holder")
        guard let text = try? String(contentsOfFile: holder, encoding: .utf8),
            let first = text.split(separator: "\n", omittingEmptySubsequences: false).first,
            !first.isEmpty
        else { return nil }
        return String(first)
    }

    /// Whether `executablePath` is a debug build from `holderRoot`'s checkout.
    static func isSeat(executablePath: String?, holderRoot: String?) -> Bool {
        guard let executablePath, let holderRoot, !holderRoot.isEmpty else { return false }
        // `.build/debug` is itself a link, to the triple's directory
        // (`.build/arm64-apple-macosx/debug`), so it's resolved whole, the
        // same way the executable's path is.
        let resolved = (executablePath as NSString).resolvingSymlinksInPath
        let debug = ((holderRoot as NSString).appendingPathComponent(".build/debug") as NSString)
            .resolvingSymlinksInPath
        return resolved.hasPrefix(debug + "/")
    }
}
