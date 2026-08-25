// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

// Source-level guard: `PeerIdentity.validateGUIPeer` must be called
// from exactly ONE place in the whole source tree:
// `defaultPeerValidator` in `Sources/Daemon/Trust/PeerValidator.swift`.
// Every other consumer of "is this the validated GUI" reads the
// resolved verdict: the stamped `DispatchPeerContext.validatedGUIPeer`
// bool, or the value the dispatcher hands the scope check. A stable
// result from the expensive `SecCode` signature walk is cached (per
// connection and per peer process) rather than repeated; every path
// goes through the injectable seam the tests exercise.
//
// The guard enforces BOTH directions: the canonical file contains
// exactly one call (so deleting or stubbing `defaultPeerValidator`
// fails the test), and no other file contains any call (so a new
// consumer that re-validates fails it). It keys the exemption on the
// exact repo-relative path, not a basename. Detection is textual: it
// counts `validateGUIPeer(` occurrences and subtracts the `func
// validateGUIPeer(` definition, so it also catches a call written in a
// comment or string literal (conservative by design) and won't flag the
// method's own declaration.

private let canonicalRelPath = "Sources/Daemon/Trust/PeerValidator.swift"

@Test
func validateGUIPeerHasExactlyOneCanonicalCallSite() throws {
    let root = repoRoot()
    let sources = root.appendingPathComponent("Sources")
    let fileManager = FileManager.default
    guard let enumerator = fileManager.enumerator(
        at: sources,
        includingPropertiesForKeys: nil
    ) else {
        Issue.record("could not enumerate \(sources.path)")
        return
    }

    var canonicalCalls = 0
    var offenders: [String] = []
    for case let url as URL in enumerator where url.pathExtension == "swift" {
        let relPath = repoRelativePath(url, root: root)
        let calls = callCount(in: try String(contentsOf: url, encoding: .utf8))
        if relPath == canonicalRelPath {
            canonicalCalls = calls
        } else if calls > 0 {
            offenders.append(relPath)
        }
    }

    // The one legitimate call must exist, exactly once. Deleting or
    // stubbing `defaultPeerValidator` drops this to zero and fails.
    #expect(
        canonicalCalls == 1,
        "expected exactly one validateGUIPeer call in \(canonicalRelPath), found \(canonicalCalls)"
    )
    // No other file may call it.
    let offenderList = offenders.sorted().joined(separator: ", ")
    let message = "validateGUIPeer must only be called from "
        + "\(canonicalRelPath); found calls in: \(offenderList). Route new "
        + "GUI-validation consumers through the resolved verdict "
        + "(DispatchPeerContext.validatedGUIPeer) instead."
    #expect(offenders.isEmpty, "\(message)")
}

/// Count `validateGUIPeer(...)` *call* sites in `text`: same-line
/// `validateGUIPeer(` occurrences minus the `func validateGUIPeer(`
/// definition. Same-line (`[ \t]*`, not `\s*`) so a call is one line
/// and the count is stable against reflowing unrelated code.
private func callCount(in text: String) -> Int {
    let calls = text.ranges(of: /validateGUIPeer[ \t]*\(/).count
    let definitions = text.ranges(of: /func[ \t]+validateGUIPeer[ \t]*\(/).count
    return calls - definitions
}

/// Path of `url` relative to `root` (e.g. `Sources/Daemon/Foo.swift`).
private func repoRelativePath(_ url: URL, root: URL) -> String {
    let prefix = root.standardizedFileURL.path + "/"
    let full = url.standardizedFileURL.path
    return full.hasPrefix(prefix) ? String(full.dropFirst(prefix.count)) : full
}

/// The repo root, derived from this test file's path
/// (`<root>/Tests/DaemonTests/Trust/ThisFile.swift`).
private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Trust
        .deletingLastPathComponent()  // DaemonTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root
}
