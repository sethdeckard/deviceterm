// SPDX-License-Identifier: GPL-3.0-or-later

import Testing

@testable import App

@Suite("pane title precedence")
struct PaneTitleDecisionTests {
    @Test("tier precedence", arguments: [
        // Every tier present: the program's own title wins.
        (["vim Login.swift", "test runner", "/Users/x/project"], "vim Login.swift"),
        // No OSC title: the pane's name stands in.
        ([nil, "test runner", "/Users/x/project"], "test runner"),
        // Neither: the directory's last component.
        ([nil, nil, "/Users/x/project"], "project"),
        // Nothing at all.
        ([nil, nil, nil], "shell")
    ] as [([String?], String)])
    func resolvesTiersInOrder(input: [String?], expected: String) {
        #expect(
            PaneTitleDecision.title(
                oscTitle: input[0],
                name: input[1],
                oscWorkingDirectory: input[2]
            ) == expected
        )
    }

    /// The ordering a reader tends to expect the other way round. `pane rename`
    /// writes the name tier, which sits below the OSC title, so a renamed pane
    /// running something keeps reporting what it is running.
    @Test
    func renameDoesNotOverrideALiveOSCTitle() {
        #expect(
            PaneTitleDecision.title(
                oscTitle: "vim Login.swift",
                name: "test runner",
                oscWorkingDirectory: nil
            ) == "vim Login.swift"
        )
    }

    /// A tier that normalizes away is skipped rather than blanking the label,
    /// so a hostile or empty title cannot erase the tiers beneath it.
    @Test("empty tiers fall through", arguments: [
        "",
        "   ",
        "\u{200B}\u{200B}",
        "\u{2800}"
    ])
    func skipsTiersThatNormalizeAway(oscTitle: String) {
        #expect(
            PaneTitleDecision.title(
                oscTitle: oscTitle,
                name: "test runner",
                oscWorkingDirectory: nil
            ) == "test runner"
        )
    }

    /// Per-pane titles use the tab-title normalizer, so they share its bounded,
    /// non-deceptive display contract.
    @Test
    func normalizesTheWinningTier() {
        #expect(
            PaneTitleDecision.title(
                oscTitle: "vim\u{0007}\u{202E}Login.swift",
                name: nil,
                oscWorkingDirectory: nil
            ) == "vimLogin.swift"
        )
    }

    @Test
    func boundsTheWinningTierToTheSharedByteBudget() {
        let long = String(repeating: "x", count: 400)
        let title = PaneTitleDecision.title(oscTitle: long, name: nil, oscWorkingDirectory: nil)
        #expect(title.utf8.count <= 256)
    }

    /// An empty path contributes no tier. Root contributes `"/"`, because
    /// `lastPathComponent` reports it that way, and the tab label's basename
    /// tier does the same. The two must agree for a single-terminal tab.
    @Test("root and empty directories", arguments: [("", "shell"), ("/", "/")])
    func matchesTheTabBasenameTierAtTheEdges(path: String, expected: String) {
        #expect(
            PaneTitleDecision.title(
                oscTitle: nil,
                name: nil,
                oscWorkingDirectory: path
            ) == expected
        )
    }

    @Test
    func usesOnlyTheLastPathComponent() {
        #expect(
            PaneTitleDecision.title(
                oscTitle: nil,
                name: nil,
                oscWorkingDirectory: "/Users/x/project/Sources/App"
            ) == "App"
        )
    }
}
