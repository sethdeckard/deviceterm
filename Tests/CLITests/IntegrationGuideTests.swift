// SPDX-License-Identifier: GPL-3.0-or-later

@testable import DeviceTermCLI
import Foundation
import Testing

// Drift guards for the public surface matrix in docs/INTEGRATION.md. Command
// prose remains hand-authored, but a catalog addition must have a visible home
// in the integration guide before the contract can silently expand.

private func locateIntegrationGuide() -> URL? {
    let testFile = URL(fileURLWithPath: #filePath)
    var current = testFile.deletingLastPathComponent()
    for _ in 0..<8 {
        let candidate = current.appendingPathComponent("docs/INTEGRATION.md")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        let parent = current.deletingLastPathComponent()
        if parent.path == current.path { return nil }
        current = parent
    }
    return nil
}

private func integrationGuide() throws -> String {
    let url = try #require(
        locateIntegrationGuide(),
        "docs/INTEGRATION.md not found relative to test source"
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
func integrationGuideSurfaceMatrixCoversEveryCataloguedCommand() throws {
    let contents = try integrationGuide()
    let matrix = try section(named: "Surface Matrix", in: contents)

    for verb in VerbCatalog.all {
        if verb.subVerbs.isEmpty {
            #expect(
                matrix.contains(verb.name),
                "surface matrix missing top-level verb '\(verb.name)'"
            )
            continue
        }
        for subVerb in verb.subVerbs {
            let command = "\(verb.name) \(subVerb)"
            #expect(matrix.contains(command), "surface matrix missing '\(command)'")
        }
    }
}

@Test
func integrationGuidePinsOutputModeExceptions() throws {
    let contents = try integrationGuide()
    let rules = try section(named: "Contract Rules", in: contents)
    for command in ["`ax tree`", "`ax point`", "`ax sweep`", "`events`"] {
        #expect(rules.contains(command), "always-JSON list missing \(command)")
    }
    for command in ["`help`", "`agents`", "`completions install`", "`with-pane`"] {
        #expect(rules.contains(command), "non-JSON list missing \(command)")
    }
}

@Test
func integrationGuideSurfaceMatrixPinsScopeCategories() throws {
    let contents = try integrationGuide()
    let matrix = try section(named: "Surface Matrix", in: contents)
    let scopedRows = [
        "| `version --json` | Version report | Local,",
        "| `tabs list --json` | Array of tab rows | Daemon-wide |",
        "| `panes list --json` | Array of pane rows | Session |",
        "| `tab send-input --json` | Input receipt | Orchestration |",
        "| `pane rename`, `pane move` | No success shape | Session | Unsupported; command fails |"
    ]
    for row in scopedRows {
        #expect(matrix.contains(row), "surface matrix scope row changed: \(row)")
    }
}

@Test
func integrationGuideHandlesFailedVersionProbeSeparately() throws {
    let contents = try integrationGuide()
    let discovery = try section(named: "Discovery and State", in: contents)
    #expect(discovery.contains("has(\"daemon\")"))
    #expect(discovery.contains("live version probe did not succeed"))
    #expect(discovery.contains("authentication, transport, RPC, or"))
}

@Test
func integrationGuidePinsExternalSimMetadataFallback() throws {
    let contents = try integrationGuide()
    let events = try section(named: "Events", in: contents)
    #expect(events.contains("xcrun simctl list devices --json"))
}

@Test
func integrationGuideDocumentsAccessibilityEnvelopes() throws {
    let contents = try integrationGuide()
    let accessibility = try section(named: "Accessibility", in: contents)
    #expect(accessibility.contains("Read an `ax tree` node through `.tree`"))
    #expect(accessibility.contains("an `ax point` node through\n`.element`"))
    #expect(accessibility.contains("\"tree\": {"))
    #expect(accessibility.contains("\"element\": {"))
}

@Test
func integrationGuideContentsMatchesH2Sections() throws {
    let contents = try integrationGuide()
    let headings = contents.split(separator: "\n")
        .compactMap { line -> String? in
            guard line.hasPrefix("## ") else { return nil }
            return String(line.dropFirst(3))
        }
        .filter { $0 != "Contents" }
    let toc = try section(named: "Contents", in: contents)
    for heading in headings {
        let anchor = heading.lowercased().replacingOccurrences(of: " ", with: "-")
        #expect(
            toc.contains("[\(heading)](#\(anchor))"),
            "contents missing H2 heading '\(heading)'"
        )
    }
}

@Test
func integrationGuideAvoidsEmAndEnDashes() throws {
    let contents = try integrationGuide()
    #expect(!contents.contains("—"), "integration guide contains an em dash")
    #expect(!contents.contains("–"), "integration guide contains an en dash")
}
