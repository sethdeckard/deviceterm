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

    for verb in CommandTree.all {
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
func integrationGuideDocumentsTypedJSONFailures() throws {
    let contents = try integrationGuide()
    let rules = try section(named: "Contract Rules", in: contents)
    for field in [#""code""#, #""message""#, #""details""#] {
        #expect(rules.contains(field), "JSON failure envelope missing field \(field)")
    }
    for code in [
        "cli.invalidUsage",
        "session.required",
        "transport.unavailable",
        "protocol.invalidResponse",
        "pane.notFound",
        "pane.bridgeFailed",
        "rpc.invalidParams",
        "intent.*"
    ] {
        #expect(rules.contains(code), "JSON failure contract missing code \(code)")
    }
    #expect(rules.contains("Branch on `error.code`"))
    #expect(rules.contains("human-readable stderr diagnostic"))
    #expect(rules.contains("nonzero exit status"))
}

@Test
func integrationGuidePinsTypedFailureBoundary() throws {
    let contents = try integrationGuide()
    let rules = try section(named: "Contract Rules", in: contents)
    #expect(rules.contains("Command-specific\nfailure paths that have not adopted"))
    #expect(rules.contains("`events` retains its JSON Lines streaming behavior"))
    #expect(rules.contains("`with-pane` continues to inherit its child process's"))
    #expect(rules.contains("A failing `doctor --json` still returns its doctor report"))
}

@Test
func integrationGuideSurfaceMatrixPinsScopeCategories() throws {
    let contents = try integrationGuide()
    let matrix = try section(named: "Surface Matrix", in: contents)
    let scopedRows = [
        "| `version --json` | Version report | Local,",
        "| `tab list --json` | Array of tab workspace rows | Session |",
        "| `pane list --json` | Array of every pane kind | Session |",
        "| `pane send-input --json` | Workspace receipt | Automation |",
        "| `pane capture-text --json` | `{pane, text}` | Automation |"
    ]
    for row in scopedRows {
        #expect(matrix.contains(row), "surface matrix scope row changed: \(row)")
    }
}

@Test
func integrationGuideDocumentsStyledCapture() throws {
    let contents = try integrationGuide()
    let section = try section(named: "Capture a Viewport", in: contents)

    #expect(section.contains("--ansi"))
    // The divergence from the plain capture is the part a consumer gets
    // wrong, so pin that it is stated rather than only the flag name.
    #expect(section.contains("not the plain capture with escapes inserted"))
    #expect(section.contains("38;5;n"))
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
func integrationGuideDocumentsWorkspaceProjectionContract() throws {
    let contents = try integrationGuide()
    let discovery = try section(named: "Discovery and State", in: contents)
    for contract in [
        "one row for each real GUI tab workspace",
        "panes in layout order",
        "Each GUI tab produces one\nrow, regardless of how many terminal splits it contains",
        "A terminal pane's `id` is its `sessionId`",
        "Exactly\none of `terminal`, `simulator`, or `device`",
        "`window show <ref> --json` returns `{window, tabs}`"
    ] {
        #expect(discovery.contains(contract), "workspace projection contract missing \(contract)")
    }
}

@Test
func integrationGuideDocumentsTerminalWorkingDirectoryProjection() throws {
    let contents = try integrationGuide()
    let matrix = try section(named: "Surface Matrix", in: contents)
    #expect(matrix.contains("optional `terminal.cwd` field has a narrower rule"))
    #expect(matrix.contains("live automation grant"))

    let discovery = try section(named: "Discovery and State", in: contents)
    for claim in [
        "`terminal.cwd` is an optional live process snapshot",
        "ungranted read still succeeds but omits the field",
        "derives fresh anchor facts",
        "verified same-user process associated with the terminal",
        "process handoff can\nleave the field absent for one read",
        "When fallback\nmust select among the session leader's children",
        "never\nsubstitutes the startup directory"
    ] {
        #expect(discovery.contains(claim), "terminal CWD contract missing: \(claim)")
    }
}

@Test
func integrationGuidePinsWorkspaceReferenceRules() throws {
    let contents = try integrationGuide()
    let rules = try section(named: "Contract Rules", in: contents)
    for claim in [
        "Names never match by prefix",
        "Window indices are output metadata only",
        "First six lowercase hexadecimal",
        "Six lowercase Crockford base32",
        "exact Simulator UDID or\nphysical device ID"
    ] {
        #expect(rules.contains(claim), "workspace reference contract missing: \(claim)")
    }
    #expect(!rules.contains("or projected index"))
}

@Test
func integrationGuidePinsTheLowercaseIdentifierRule() throws {
    // The rule the guide states and the spelling the code emits are two
    // separate things. Keep the casing contract explicit for workspace and
    // session ids, including the equality with `$DEVICETERM_SESSION`.
    let rules = try section(named: "Contract Rules", in: try integrationGuide())
    for claim in [
        "DeviceTerm mints every\nidentifier in one spelling",
        "all print lowercase",
        "equals\n`$DEVICETERM_SESSION`",
        "the case to\nwatch"
    ] {
        #expect(rules.contains(claim), "identifier casing contract missing: \(claim)")
    }
}

@Test
func integrationGuidePinsPaneMutationAuthorityAndMode() throws {
    let contents = try integrationGuide()
    let automation = try section(named: "Automation", in: contents)
    #expect(automation.contains("terminal target must be the caller's exact session"))
    #expect(automation.contains("physical-device targets retain tab ownership"))
    #expect(automation.contains("live automation grant satisfies these target checks"))

    let receipts = try section(named: "Action Receipts", in: contents)
    #expect(receipts.contains("explicit `pane close --mode` is valid only"))
    #expect(receipts.contains("terminal or physical-device pane fails with\n`intent.unsupportedPane`"))
}

@Test
func integrationGuidePinsRenameGrammar() throws {
    let contents = try integrationGuide()
    let rules = try section(named: "Contract Rules", in: contents)
    #expect(rules.contains("accept one positional argument for the current\nobject or two"))
    #expect(rules.contains("Quote a name containing spaces"))
    #expect(rules.contains("beginning with `-` is read as a flag"))
    #expect(rules.contains("More than two positionals is a usage error"))
}

@Test
func integrationGuidePinsWorkspaceIntentFailures() throws {
    let contents = try integrationGuide()
    let rules = try section(named: "Contract Rules", in: contents)
    for code in [
        "intent.automationRequired",
        "intent.wouldCloseTab",
        "intent.unsupportedPane",
        "intent.mutationFailed"
    ] {
        #expect(rules.contains(code), "workspace failure contract missing \(code)")
    }
    let receipts = try section(named: "Action Receipts", in: contents)
    #expect(receipts.contains("error.details.committed"))
    #expect(receipts.contains("retain `error.details.committed.tab.id`"))
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
func integrationGuideDocumentsReusableAccessibilityCoordinates() throws {
    let contents = try integrationGuide()
    let accessibility = try section(named: "Accessibility", in: contents)
    #expect(accessibility.contains("optional and DeviceTerm-owned"))
    #expect(accessibility.contains("Pass them\ndirectly to `tap`"))
    #expect(accessibility.contains("node lacks a finite origin or positive finite dimensions"))
    #expect(accessibility.contains("Omission is a successful result, not an error"))
    #expect(accessibility.contains("synthetic root itself never receives the field"))
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
