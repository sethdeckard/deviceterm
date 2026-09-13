// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

// Drift guards for docs/AUTOMATION.md: the wait recipes use the CLI primitive
// rather than hand-written polling, and the contents list stays in step with
// the H2 sections.

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
func automationGuideUsesTheCLIWaitPrimitive() throws {
    let contents = try automationGuide()
    let waits = try section(named: "Wait for Device State", in: contents)
    #expect(waits.contains("deviceterm wait pane rendering"))
    #expect(waits.contains("deviceterm wait ax"))
    #expect(waits.contains("deviceterm wait orientation"))
    #expect(!waits.contains("while ! deviceterm"))
    #expect(waits.contains("An individual RPC deadline remains `transport.timeout`"))
}

@Test
func automationGuideDocumentsLiveWorkspaceProjection() throws {
    let contents = try automationGuide()
    let discovery = try section(named: "Discover State", in: contents)
    #expect(discovery.contains("live GUI state"))
    #expect(discovery.contains("`{tab, panes, layout}`"))
    #expect(discovery.contains("every terminal, Simulator, and physical-device leaf"))
    #expect(discovery.contains("An empty list with exit 0 is a successful empty visibility projection"))
    #expect(discovery.contains("window indices do not participate in resolution"))
    #expect(discovery.contains("Names match exactly, never by prefix"))

    let driving = try section(named: "Drive Other Tabs", in: contents)
    #expect(driving.contains("pane send-input \"$TARGET_PANE\""))
    #expect(driving.contains("pane capture-text \"$TARGET_PANE\""))
    #expect(driving.contains("explicit terminal pane reference"))
    #expect(driving.contains("live\nautomation grant"))
}

@Test
func automationGuideDocumentsTerminalWorkingDirectoryReads() throws {
    let contents = try automationGuide()
    let discovery = try section(named: "Discover State", in: contents)
    #expect(discovery.contains("pane show \"$PANE\" --json | jq -er '.terminal.cwd'"))
    #expect(discovery.contains("Every command takes a fresh process snapshot"))
    #expect(discovery.contains("requires a live automation grant"))
    #expect(discovery.contains("successful workspace response with `cwd`\nomitted"))
    #expect(discovery.contains("Do not fall back to a startup `--cwd` value"))
}

@Test
func automationGuidePreservesOperationalSections() throws {
    let contents = try automationGuide()
    let headings = [
        "### Know Your Session",
        "### Trust the Terminal, Not the Token",
        "### Escalate Only Through the GUI",
        "### Open Tabs, Panes, and Windows",
        "### Arrange, Select, and Close Surfaces",
        "### List Tabs, Panes, Windows, and Devices",
        "### Read Terminal Working Directories",
        "### Resolve Workspace References",
        "### Check Health With doctor",
        "### Diagnose Version Skew",
        "### Open an Automation Tab",
        "### Send Input to Another Tab",
        "### Capture Another Tab",
        "### Protect a Tab",
        "### Use Wait for One-Shot Convergence",
        "### Use Events as a Latency Signal"
    ]
    for heading in headings {
        #expect(contents.contains(heading), "automation guide is missing '\(heading)'")
    }
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
