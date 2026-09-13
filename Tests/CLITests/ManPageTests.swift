// SPDX-License-Identifier: GPL-3.0-or-later

@testable import DeviceTermCLI
import Foundation
import Testing

// Assert the `deviceterm.1` man page exists at the repo-relative path
// and carries the canonical section headers + the load-bearing
// command grouping. The man page is hand-authored groff
// (not generated); these tests are the regression guard that a future
// edit doesn't accidentally drop a major section.
//
// Path resolution: walk up from the test source file to the repo
// root, then look for `share/man/man1/deviceterm.1`. Tied to filesystem
// layout, but the layout is stable and `make verify` runs from the
// repo root.

private func locateManPage() -> URL? {
    let testFile = URL(fileURLWithPath: #filePath)
    var current = testFile.deletingLastPathComponent()
    for _ in 0..<8 {
        let candidate = current.appendingPathComponent(
            "share/man/man1/deviceterm.1"
        )
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        let parent = current.deletingLastPathComponent()
        if parent.path == current.path { return nil }
        current = parent
    }
    return nil
}

@Test
func manPageExistsAtSharePath() throws {
    let url = try #require(
        locateManPage(),
        "share/man/man1/deviceterm.1 not found relative to test source"
        )
    #expect(FileManager.default.fileExists(atPath: url.path))
}

@Test
func manPageCarriesCanonicalSections() throws {
    let url = try #require(locateManPage())
    let contents = try String(contentsOf: url, encoding: .utf8)
    for section in [
        ".SH NAME",
        ".SH SYNOPSIS",
        ".SH DESCRIPTION",
        ".SH COMMANDS",
        ".SH OUTPUT",
        ".SH ENVIRONMENT",
        ".SH FILES",
        ".SH DIAGNOSTICS",
        ".SH SEE ALSO"
    ] {
        #expect(
            contents.contains(section),
            "man page missing section '\(section)'"
            )
    }
}

@Test
func manPageCoversTouchAndHardwareInputCommands() throws {
    // Spot-check that the major verb groupings made it in. Anchors
    // on the section subheaders + a handful of representative verbs.
    let url = try #require(locateManPage())
    let contents = try String(contentsOf: url, encoding: .utf8)
    // The subheaders are the CLI's group titles, so a reader who learned
    // the shape from `deviceterm help` meets it again here.
    for group in HelpTopic.Group.allCases {
        #expect(
            contents.contains(".SS \(group.title)"),
            "man page missing subsection '\(group.title)'"
            )
    }
    for verb in [
        "tap",
        "swipe",
        "long-press",
        "pinch",
        "button",
        "key",
        "text",
        "rotate",
        "crown",
        "ax tree",
        "with-pane",
        "devices list",
        "tab open",
        "tab close",
        "tab rename",
        "tab focus",
        "tab protect",
        "pane list",
        "pane split",
        "pane close",
        "pane send-input",
        "pane capture-text",
        "--ansi",
        "device attach",
        "window open",
        "window close",
        "window focus",
        "window list",
        "completions install"
    ] {
        #expect(
            contents.contains(verb),
            "man page missing verb '\(verb)'"
            )
    }
}

@Test
func manPageCarriesReusableAccessibilityCoordinates() throws {
    let url = try #require(locateManPage())
    let contents = try String(contentsOf: url, encoding: .utf8)
    #expect(contents.contains("Each usable node\nincludes\n.B normalizedCenter"))
    #expect(contents.contains("can be passed directly to\nanother coordinate-bearing verb"))
    #expect(contents.contains("synthetic sweep root remains a 0,0,1,1 placeholder"))
}

@Test
func manPageCoversEveryTopLevelVerb() throws {
    // The man page is the full-text reference, so a verb absent from it
    // has no long-form home at all.
    let url = try #require(locateManPage())
    let contents = try String(contentsOf: url, encoding: .utf8)
    for verb in CommandTree.all.map(\.name) {
        #expect(
            contents.contains(".B \(verb)"),
            "man page missing verb '\(verb)'"
            )
    }
}

@Test
func manPageCoversEverySubVerb() throws {
    // Same contract the help pages carry: a sub-verb the completion
    // scripts offer has to be explained somewhere a reader can find it.
    let url = try #require(locateManPage())
    let contents = try String(contentsOf: url, encoding: .utf8)
    for verb in CommandTree.all where !verb.subVerbs.isEmpty {
        for sub in verb.subVerbs {
            #expect(
                contents.contains("\(verb.name) \(sub)"),
                "man page missing '\(verb.name) \(sub)'"
                )
        }
    }
}

@Test
func manPageHasThHeader() throws {
    // `.TH` is the man-page title macro. It supplies the section header
    // when the checkout's page renders under
    // `man ./share/man/man1/deviceterm.1`.
    let url = try #require(locateManPage())
    let contents = try String(contentsOf: url, encoding: .utf8)
    #expect(contents.contains(".TH DEVICETERM 1"))
}

@Test
func manPageExplainsHowToSendDashedWordsLiterally() throws {
    let url = try #require(locateManPage())
    let contents = try String(contentsOf: url, encoding: .utf8)
    #expect(contents.contains("is read as a flag"))
    #expect(contents.contains("before the text to send such a word literally"))
}

@Test
func manPagePinsWorkspaceReferenceRules() throws {
    let url = try #require(locateManPage())
    let contents = try String(contentsOf: url, encoding: .utf8)
    #expect(contents.contains("Names match\nexactly, never by prefix"))
    #expect(contents.contains("is display-order metadata, not a reference"))
    #expect(contents.contains("first six lowercase hexadecimal characters"))
    #expect(contents.contains("six lowercase Crockford base32 characters"))
    #expect(!contents.contains("one-based\nindex from"))
}

@Test
func manPagePinsPaneMutationAuthorityAndMode() throws {
    let url = try #require(locateManPage())
    let contents = try String(contentsOf: url, encoding: .utf8)
    #expect(contents.contains("an ungranted caller may target only its own terminal\nsession"))
    #expect(contents.contains("Simulator and physical-device panes retain target-tab ownership"))
    #expect(contents.contains("An explicit mode is valid only for a Simulator pane"))
    #expect(contents.contains("intent.unsupportedPane"))
    #expect(contents.contains("intent.wouldCloseTab"))
}

@Test
func manPagePinsBoundedRenameGrammar() throws {
    let url = try #require(locateManPage())
    let contents = try String(contentsOf: url, encoding: .utf8)
    #expect(contents.components(separatedBy: "than two positionals is a usage error").count == 3)
    #expect(contents.components(separatedBy: "before the name to use it literally").count == 3)
}

@Test
func manPagePinsPartialMutationFailure() throws {
    let url = try #require(locateManPage())
    let contents = try String(contentsOf: url, encoding: .utf8)
    #expect(contents.contains("intent.mutationFailed"))
    #expect(contents.contains("error.details.committed"))
}
