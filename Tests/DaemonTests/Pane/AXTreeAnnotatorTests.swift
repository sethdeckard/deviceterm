// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

// AXTreeAnnotator decides whether to inject a `note` into the daemon's
// `ax tree` response. The rule is narrow: empty children AND watchOS
// family → inject `AXTreeNote.watchOSEnumerationUnsupported`. Anything
// else (non-watch, or watch-but-actually-has-children) passes through
// untouched. Pinning the matrix here matters because the live test
// runs against the BRIDGE layer (which never injects the note), so this
// is the only place the daemon-side decision is exercised
// deterministically.

// Source the expected note from the wire enum rather than re-declaring
// the literal. `AXTreeNoteTests.watchOSEnumerationUnsupportedRawValueIsStable`
// pins the exact rawValue, so reusing it here keeps the annotator
// tests non-fragile across note-text rephrasings.
private let expectedNote = AXTreeNote.watchOSEnumerationUnsupported.rawValue
private let expectedNoteCode = AXTreeNote.watchOSEnumerationUnsupported.code

@Test
func injectsNoteOnEmptyWatchOSTree() {
    let tree: [String: Any] = [
        "role": "Application",
        "frame": ["x": 0, "y": 0, "w": 396, "h": 484],
        "children": []
    ]
    let annotated = AXTreeAnnotator.annotate(tree: tree, family: .watch)
    #expect(annotated["note"] as? String == expectedNote)
    #expect(annotated["noteCode"] as? String == expectedNoteCode)
    #expect((annotated["children"] as? [Any])?.isEmpty == true)
    #expect(annotated["role"] as? String == "Application")
}

@Test
func doesNotInjectWhenWatchOSChildrenNonEmpty() {
    // Future Apple-fix case: watchOS may someday return enumerable
    // children. The annotator should NOT then claim enumeration is
    // unsupported: drop the note based on observed behavior, not
    // family alone.
    let tree: [String: Any] = [
        "role": "Application",
        "children": [["role": "Button"]]
    ]
    let annotated = AXTreeAnnotator.annotate(tree: tree, family: .watch)
    #expect(annotated["note"] == nil)
    #expect(annotated["noteCode"] == nil)
}

@Test
func doesNotInjectOnEmptyPhoneTree() {
    // Empty children on phone/pad/tv is a legitimate state (no
    // visible UI in this app screen); the note would be misleading.
    let tree: [String: Any] = [
        "role": "Application",
        "children": []
    ]
    #expect(AXTreeAnnotator.annotate(tree: tree, family: .phone)["note"] == nil)
    #expect(AXTreeAnnotator.annotate(tree: tree, family: .pad)["note"] == nil)
    #expect(AXTreeAnnotator.annotate(tree: tree, family: .tv)["note"] == nil)
    #expect(AXTreeAnnotator.annotate(tree: tree, family: .unknown)["note"] == nil)
}

@Test
func doesNotInjectWhenChildrenKeyMissing() {
    // Defensive: a tree dict that lacks the `children` key entirely
    // shouldn't trip the annotator into injecting either. The bridge
    // always sets the key but we don't want to depend on that
    // contract upstream.
    let tree: [String: Any] = ["role": "Application"]
    let annotated = AXTreeAnnotator.annotate(tree: tree, family: .watch)
    #expect(annotated["note"] == nil)
    #expect(annotated["noteCode"] == nil)
}

@Test
func passesThroughOtherKeysUnchanged() {
    // The annotator is purely additive: it never mutates or drops
    // existing keys. Verify with a tree that has a typical full set.
    let tree: [String: Any] = [
        "role": "Application",
        "label": "TestApp",
        "identifier": "com.example.test",
        "subrole": "AXSwitch",
        "value": "off",
        "frame": ["x": 1, "y": 2, "w": 3, "h": 4],
        "children": []
    ]
    let annotated = AXTreeAnnotator.annotate(tree: tree, family: .watch)
    #expect(annotated["role"] as? String == "Application")
    #expect(annotated["label"] as? String == "TestApp")
    #expect(annotated["identifier"] as? String == "com.example.test")
    #expect(annotated["subrole"] as? String == "AXSwitch")
    #expect(annotated["value"] as? String == "off")
    #expect(annotated["frame"] is [String: Any])
    #expect((annotated["children"] as? [Any])?.isEmpty == true)
    #expect(annotated["note"] as? String == expectedNote)
    #expect(annotated["noteCode"] as? String == expectedNoteCode)
}
