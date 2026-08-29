// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

// Drift guards for docs/AUTOMATION.md: the wait recipes keep normalized
// UDID matching and the stalled-boot caveat, and the contents list stays in
// step with the H2 sections.

private func locateAutomationGuide() -> URL? {
    let testFile = URL(fileURLWithPath: #filePath)
    var current = testFile.deletingLastPathComponent()
    for _ in 0..<8 {
        let candidate = current.appendingPathComponent("docs/AUTOMATION.md")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        let parent = current.deletingLastPathComponent()
        if parent.path == current.path { return nil }
        current = parent
    }
    return nil
}

private func automationGuide() throws -> String {
    let url = try #require(
        locateAutomationGuide(),
        "docs/AUTOMATION.md not found relative to test source"
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
func automationGuideNormalizesSimulatorIDsInWaits() throws {
    let contents = try automationGuide()
    let events = try section(named: "Wait on Events", in: contents)
    let normalizationCount = events.components(separatedBy: "ascii_downcase").count - 1
    #expect(normalizationCount == 6)
    #expect(events.contains("does not bound\na stalled boot command"))
}

@Test
func automationGuideGroupsAndTargetsTabsByTabId() throws {
    let contents = try automationGuide()
    let discovery = try section(named: "Discover State", in: contents)
    #expect(discovery.contains("group_by(.tabId)"))
    #expect(discovery.contains("unique | length"))
    #expect(discovery.contains("visible session groups"))
    #expect(discovery.contains("does\nnot mark non-GUI groups"))
    #expect(discovery.contains("`[]` with exit 0"))

    let driving = try section(named: "Drive Other Tabs", in: contents)
    #expect(driving.contains("select(.name == \"auth-feature\") | .tabId"))
    #expect(driving.contains("known to name a GUI-backed session"))
    #expect(driving.contains("this selection is not reliable"))
    #expect(driving.contains("tab send-input --tab \"$TARGET_TAB\""))
    #expect(driving.contains("accepted anywhere `--tab <ref>` is accepted"))
}

@Test
func automationGuideContentsMatchesH2Sections() throws {
    let contents = try automationGuide()
    let headings = contents.split(separator: "\n")
        .compactMap { line -> String? in
            guard line.hasPrefix("## ") else { return nil }
            return String(line.dropFirst(3))
        }
        .filter { $0 != "Contents" }
    let toc = try section(named: "Contents", in: contents)
    for heading in headings {
        let anchor = heading.lowercased()
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "-")
        #expect(
            toc.contains("[\(heading)](#\(anchor))"),
            "contents missing H2 heading '\(heading)'"
        )
    }
    // The reverse direction: a contents entry left behind after a section
    // is removed or renamed must fail, not linger as a dead link.
    let tocTitles = toc.split(separator: "\n").compactMap { line -> String? in
        guard line.hasPrefix("- ["), let close = line.firstIndex(of: "]")
        else { return nil }
        return String(line[line.index(line.startIndex, offsetBy: 3)..<close])
    }
    for title in tocTitles {
        #expect(
            headings.contains(title),
            "contents lists section '\(title)' that has no H2"
        )
    }
}

@Test
func automationGuideAvoidsEmAndEnDashes() throws {
    let contents = try automationGuide()
    #expect(!contents.contains("—"), "automation guide contains an em dash")
    #expect(!contents.contains("–"), "automation guide contains an en dash")
}
