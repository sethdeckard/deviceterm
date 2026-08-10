// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation
import Testing

@testable import DeviceTermUITest

@Suite("keyboard shortcut parsing")
struct KeyShortcutTests {
    @Test
    func parsesABareKey() throws {
        let shortcut = try KeyShortcutParser.parse("t")
        #expect(shortcut.keyCode == 17)
        #expect(shortcut.flags.isEmpty)
    }

    @Test
    func parsesACommandShortcut() throws {
        let shortcut = try KeyShortcutParser.parse("cmd+t")
        #expect(shortcut.keyCode == 17)
        #expect(shortcut.flags == .maskCommand)
    }

    @Test
    func combinesMultipleModifiers() throws {
        let shortcut = try KeyShortcutParser.parse("cmd+shift+left")
        #expect(shortcut.keyCode == 123)
        #expect(shortcut.flags.contains(.maskCommand))
        #expect(shortcut.flags.contains(.maskShift))
    }

    @Test("modifier aliases agree", arguments: [
        ("opt+a", "alt+a"),
        ("alt+a", "option+a"),
        ("ctrl+a", "control+a"),
        ("cmd+a", "command+a")
    ])
    func modifierAliasesAgree(lhs: String, rhs: String) throws {
        #expect(try KeyShortcutParser.parse(lhs) == KeyShortcutParser.parse(rhs))
    }

    @Test
    func isCaseInsensitiveAndTolerantOfSpaces() throws {
        #expect(try KeyShortcutParser.parse("CMD + Shift + T")
            == KeyShortcutParser.parse("cmd+shift+t"))
    }

    @Test("named keys resolve", arguments: [
        ("return", CGKeyCode(36)),
        ("enter", CGKeyCode(36)),
        ("tab", CGKeyCode(48)),
        ("space", CGKeyCode(49)),
        ("escape", CGKeyCode(53)),
        ("esc", CGKeyCode(53)),
        ("up", CGKeyCode(126)),
        ("down", CGKeyCode(125))
    ])
    func namedKeysResolve(name: String, code: CGKeyCode) throws {
        #expect(try KeyShortcutParser.parse(name).keyCode == code)
    }

    /// A shortcut must name exactly one key. "cmd" alone isn't a gesture,
    /// and "cmd+t+w" is a typo we must not guess at.
    @Test
    func rejectsAModifierWithNoKey() {
        #expect(throws: KeyShortcutError.missingKey) {
            _ = try KeyShortcutParser.parse("cmd+shift")
        }
    }

    @Test
    func rejectsTwoKeys() {
        #expect(throws: KeyShortcutError.multipleKeys("t", "w")) {
            _ = try KeyShortcutParser.parse("cmd+t+w")
        }
    }

    @Test
    func rejectsAnUnknownToken() {
        #expect(throws: KeyShortcutError.unknownToken("hyper")) {
            _ = try KeyShortcutParser.parse("hyper+t")
        }
    }

    @Test
    func rejectsAnEmptyShortcut() {
        #expect(throws: KeyShortcutError.empty) { _ = try KeyShortcutParser.parse("") }
        #expect(throws: KeyShortcutError.empty) { _ = try KeyShortcutParser.parse("+++") }
    }

    /// The shortcuts the playbook actually uses must all parse. An agent
    /// reads a chord out of the playbook and hands it to the parser
    /// verbatim, so one the parser rejects is a scenario that cannot be
    /// run at all.
    @Test("playbook shortcuts parse", arguments: [
        "cmd+t", "cmd+w", "opt+cmd+w", "cmd+q", "cmd+d", "cmd+shift+d",
        "cmd+shift+left", "cmd+shift+right", "ctrl+shift+d",
        "cmd+[", "cmd+]",
        "opt+cmd+left", "opt+cmd+right", "opt+cmd+up", "opt+cmd+down",
        "escape"
    ])
    func playbookShortcutsParse(text: String) throws {
        _ = try KeyShortcutParser.parse(text)
    }
}
