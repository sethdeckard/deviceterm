// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import Testing

// Drift guards for docs/ARCHITECTURE.md. The RPC protocol section is the
// canonical method schema: every RPCMethod case must have an entry heading
// there, and every entry heading must name a real method, so the doc and
// the wire surface cannot drift apart silently. The registry side of the
// same contract lives in DaemonTests (registry keys equal RPCMethod cases).

private func locateArchitectureGuide() -> URL? {
    let testFile = URL(fileURLWithPath: #filePath)
    var current = testFile.deletingLastPathComponent()
    for _ in 0..<8 {
        let candidate = current.appendingPathComponent("docs/ARCHITECTURE.md")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        let parent = current.deletingLastPathComponent()
        if parent.path == current.path { return nil }
        current = parent
    }
    return nil
}

private func architectureGuide() throws -> String {
    let url = try #require(
        locateArchitectureGuide(),
        "docs/ARCHITECTURE.md not found relative to test source"
    )
    return try String(contentsOf: url, encoding: .utf8)
}

private func section(
    named heading: String,
    in contents: String
) throws -> Substring {
    let startMarker = "## \(heading)\n"
    let start = try #require(contents.range(of: startMarker)?.upperBound)
    let tail = contents[start...]
    let end = tail.range(of: "\n## ")?.lowerBound ?? contents.endIndex
    return contents[start..<end]
}

@Test
func architectureGuideDocumentsEveryRPCMethod() throws {
    let contents = try architectureGuide()
    let rpc = try section(named: "RPC protocol", in: contents)

    // Entry headings are H4 lines whose backticked tokens are wire method
    // names, e.g. `#### `pane.subscribe``. Keying on headings (not any
    // backticked mention in the section) keeps the guard exact: prose that
    // merely references a method does not count as documenting it.
    var documented: Set<String> = []
    for line in rpc.split(separator: "\n", omittingEmptySubsequences: false)
    where line.hasPrefix("#### ") {
        let pieces = line.split(separator: "`", omittingEmptySubsequences: false)
        for (index, piece) in pieces.enumerated() where index % 2 == 1 {
            documented.insert(String(piece))
        }
    }

    let methodNames = Set(RPCMethod.allCases.map(\.rawValue))
    for name in methodNames.sorted() {
        #expect(
            documented.contains(name),
            "RPC reference has no entry heading for '\(name)'"
        )
    }
    for token in documented.sorted() where token.contains(".") {
        #expect(
            methodNames.contains(token),
            "RPC entry heading names unknown method '\(token)'"
        )
    }
}

@Test
func architectureGuideAvoidsEmAndEnDashes() throws {
    let contents = try architectureGuide()
    #expect(!contents.contains("—"), "architecture guide contains an em dash")
    #expect(!contents.contains("–"), "architecture guide contains an en dash")
}

@Test
func architectureGuideDocumentsAccessibilityCoordinateAnnotation() throws {
    let contents = try architectureGuide()
    let rpc = try section(named: "RPC protocol", in: contents)
    #expect(rpc.contains("DeviceTerm-owned optional `normalizedCenter`"))
    #expect(rpc.contains("real frontmost tree's width and height"))
    #expect(rpc.contains("The synthetic sweep\nroot is not annotated"))
}

@Test
func architectureGuideFencesCarryInfoStrings() throws {
    let contents = try architectureGuide()
    var insideFence = false
    let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
    for (index, line) in lines.enumerated() where line.hasPrefix("```") {
        if insideFence {
            insideFence = false
            continue
        }
        insideFence = true
        #expect(
            line != "```",
            "bare fence opens at line \(index + 1); tag it (text, jsonc, mermaid)"
        )
    }
}

@Test
func architectureGuidePinsInboundSectionNames() throws {
    // These H2 names are referenced by quoted title from outside the doc
    // (scripts/make-app-bundle.sh, docs/PHILOSOPHY.md, the entitlements
    // file). Renaming one silently strands those references. Matching collected H2 lines, not a
    // substring of the whole file, so a demoted heading ("### ..."), or
    // the name appearing in prose or a fence, cannot satisfy the guard.
    let contents = try architectureGuide()
    var headings: [Substring] = []
    var insideFence = false
    for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix("```") {
            insideFence.toggle()
            continue
        }
        if !insideFence, line.hasPrefix("## ") {
            headings.append(line)
        }
    }
    for name in [
        "## Process layout",
        "## Daemon lifecycle",
        "## Tab semantics",
        "## Distribution"
    ] {
        #expect(
            headings.contains { $0 == name || $0.hasPrefix("\(name) ") },
            "pinned H2 missing: '\(name)'"
        )
    }
}
