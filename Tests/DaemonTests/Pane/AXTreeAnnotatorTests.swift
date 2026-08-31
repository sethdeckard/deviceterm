// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

// AXTreeAnnotator decides where to hit-test an `ax tree` response and which
// `note` the answer earns. Two rules, one note slot. The watch rule is
// inference from a platform limitation: empty children AND watchOS family
// yields `watchOSEnumerationUnsupported`. The other is evidence: a point no
// node covers, hit-tested, answering with an element the walk did not produce
// yields `treeIncomplete`. Pinning the matrix here matters because the live
// test runs against the BRIDGE layer (which never injects a note), so this is
// the only place the daemon-side decision is exercised deterministically.

// Source the expected notes from the wire enum rather than re-declaring the
// literals. `AXTreeNoteTests` pins the exact rawValues, so reusing them here
// keeps the annotator tests non-fragile across note-text rephrasings.
private let expectedNote = AXTreeNote.watchOSEnumerationUnsupported.rawValue
private let expectedNoteCode = AXTreeNote.watchOSEnumerationUnsupported.code
private let expectedIncompleteNote = AXTreeNote.treeIncomplete.rawValue
private let expectedIncompleteNoteCode = AXTreeNote.treeIncomplete.code

// The shapes below use geometry observed on an iOS 27.0 simulator, so the
// fixtures exercise what the rules were written against rather than a
// convenient invention.

private func chromeButton(label: String, identifier: String, x: Double) -> [String: Any] {
    [
        "role": "Button",
        "label": label,
        "identifier": identifier,
        "frame": ["x": x, "y": 792, "w": 48, "h": 48],
        "children": []
    ]
}

/// Safari on a Wikipedia article: a fullscreen root whose only children are
/// chrome, confined to the bottom toolbar band. The screen centre (201, 437)
/// falls in the roughly 90% of the screen no node describes.
private func safariChromeTree() -> [String: Any] {
    [
        "role": "Application",
        "label": "Safari",
        "frame": ["x": 0, "y": 0, "w": 402, "h": 874],
        "children": [
            chromeButton(label: "Back", identifier: "BackButton", x: 34),
            chromeButton(label: "Tabs", identifier: "TabOverviewButton", x: 320)
        ]
    ]
}

/// What hit-testing Safari's centre returns: page content the walk never
/// reached, strictly inside the root frame.
private func safariPageText() -> [String: Any] {
    [
        "role": "StaticText",
        "label": "For Wikipedia's accessibility guideline, see",
        "frame": ["x": 23, "y": 436, "w": 272, "h": 19]
    ]
}

/// What hit-testing Files' centre returns: an unlabelled container whose frame
/// is exactly the root's. This is `objectAtPoint:` falling back rather than
/// finding, and rejecting it is the containment rule's whole purpose.
private func fullScreenFallback() -> [String: Any] {
    ["role": "Group", "frame": ["x": 0, "y": 0, "w": 402, "h": 874]]
}

/// A fullscreen root with one child, placed where the caller needs it.
private func rootTree(child: [String: Any]) -> [String: Any] {
    [
        "role": "Application",
        "frame": ["x": 0, "y": 0, "w": 402, "h": 874],
        "children": [child]
    ]
}

// MARK: - The watch rule

@Test
func injectsNoteOnEmptyWatchOSTree() {
    let tree: [String: Any] = [
        "role": "Application",
        "frame": ["x": 0, "y": 0, "w": 396, "h": 484],
        "children": []
    ]
    let annotated = AXTreeAnnotator.annotate(tree: tree, family: .watch, probedElement: nil)
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
    let annotated = AXTreeAnnotator.annotate(tree: tree, family: .watch, probedElement: nil)
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
    for family in [DeviceFamily.phone, .pad, .tv, .unknown] {
        let annotated = AXTreeAnnotator.annotate(
            tree: tree,
            family: family,
            probedElement: nil
        )
        #expect(annotated["note"] == nil)
    }
}

@Test
func doesNotInjectWhenChildrenKeyMissing() {
    // Defensive: a tree dict that lacks the `children` key entirely
    // shouldn't trip the annotator into injecting either. The bridge
    // always sets the key but we don't want to depend on that
    // contract upstream.
    let tree: [String: Any] = ["role": "Application"]
    let annotated = AXTreeAnnotator.annotate(tree: tree, family: .watch, probedElement: nil)
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
    let annotated = AXTreeAnnotator.annotate(tree: tree, family: .watch, probedElement: nil)
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

// MARK: - Where to probe

@Test
func probesTheCentreWhenNoDescendantCoversIt() {
    let probe = AXTreeAnnotator.probePoint(for: safariChromeTree(), family: .phone)
    #expect(probe == CGPoint(x: 0.5, y: 0.5))
}

@Test
func doesNotProbeWhenADescendantCoversTheCentre() {
    // The ordinary healthy screen, and the reason the probe costs nothing
    // there: a settings row, a list cell, anything spanning the middle.
    let covering: [String: Any] = [
        "role": "Button",
        "label": "Action Button",
        "frame": ["x": 16, "y": 397, "w": 370, "h": 52],
        "children": []
    ]
    #expect(AXTreeAnnotator.probePoint(for: rootTree(child: covering), family: .phone) == nil)
}

@Test
func doesNotCountTheRootAsCoveringTheCentre() {
    // The root's frame spans the screen, so counting it would cover every
    // point and no tree would ever be probed. Without this exclusion the
    // whole rule is dead and nothing else here would notice.
    let rootOnly: [String: Any] = [
        "role": "Application",
        "frame": ["x": 0, "y": 0, "w": 402, "h": 874],
        "children": []
    ]
    #expect(AXTreeAnnotator.probePoint(for: rootOnly, family: .phone) != nil)
}

@Test
func findsCoverageAtAnyDepth() {
    // A node covering the centre suppresses the probe wherever it sits, so
    // the walk cannot stop at the root's direct children.
    let grandchild: [String: Any] = [
        "role": "Button",
        "frame": ["x": 16, "y": 400, "w": 370, "h": 52],
        "children": []
    ]
    let group: [String: Any] = [
        "role": "Group",
        "frame": ["x": 0, "y": 62, "w": 402, "h": 160],
        "children": [grandchild]
    ]
    #expect(AXTreeAnnotator.probePoint(for: rootTree(child: group), family: .phone) == nil)
}

@Test
func doesNotProbeAWatchTreeThatAlreadyEarnedItsNote() {
    // The watch note wins regardless of what a probe found, so spending a
    // bridge call on every watchOS `ax tree` would buy nothing.
    let tree: [String: Any] = [
        "role": "Application",
        "frame": ["x": 0, "y": 0, "w": 396, "h": 484],
        "children": []
    ]
    #expect(AXTreeAnnotator.probePoint(for: tree, family: .watch) == nil)
}

@Test
func doesNotProbeWhenTheRootFrameIsUnusable() {
    // No frame, a zero dimension, or a non-finite one all leave the sample
    // point unmappable, so there is nothing to ask the bridge.
    let noFrame: [String: Any] = ["role": "Application", "children": []]
    #expect(AXTreeAnnotator.probePoint(for: noFrame, family: .phone) == nil)

    let zeroWidth: [String: Any] = [
        "role": "Application",
        "frame": ["x": 0, "y": 0, "w": 0, "h": 874],
        "children": []
    ]
    #expect(AXTreeAnnotator.probePoint(for: zeroWidth, family: .phone) == nil)

    let infiniteWidth: [String: Any] = [
        "role": "Application",
        "frame": ["x": 0, "y": 0, "w": Double.infinity, "h": 874],
        "children": []
    ]
    #expect(AXTreeAnnotator.probePoint(for: infiniteWidth, family: .phone) == nil)
}

// MARK: - What the probe result means

@Test
func notesATreeAProbeProvesIncomplete() {
    let annotated = AXTreeAnnotator.annotate(
        tree: safariChromeTree(),
        family: .phone,
        probedElement: safariPageText()
    )
    #expect(annotated["note"] as? String == expectedIncompleteNote)
    #expect(annotated["noteCode"] as? String == expectedIncompleteNoteCode)
}

@Test
func doesNotNoteWithoutAProbeResult() {
    // Absence of evidence is not a note. A tree whose descendants cover
    // nothing still says nothing about itself until a hit-test answers.
    let annotated = AXTreeAnnotator.annotate(
        tree: safariChromeTree(),
        family: .phone,
        probedElement: nil
    )
    #expect(annotated["note"] == nil)
    #expect(annotated["noteCode"] == nil)
}

@Test
func rejectsAProbeResultThatFillsTheRootFrame() {
    // `objectAtPoint:` answers with an enclosing container when nothing
    // specific sits under the point. Treating that as a finding would report
    // a healthy screen incomplete, which is the one failure that costs a
    // caller something.
    let noRecents: [String: Any] = [
        "role": "StaticText",
        "label": "No Recents",
        "frame": ["x": 142, "y": 518, "w": 118, "h": 26],
        "children": []
    ]
    let annotated = AXTreeAnnotator.annotate(
        tree: rootTree(child: noRecents),
        family: .phone,
        probedElement: fullScreenFallback()
    )
    #expect(annotated["note"] == nil)
    #expect(annotated["noteCode"] == nil)
}

@Test
func rejectsAProbeResultReachingPastTheRoot() {
    let oversized: [String: Any] = [
        "role": "Group",
        "frame": ["x": -10, "y": 0, "w": 500, "h": 900]
    ]
    let annotated = AXTreeAnnotator.annotate(
        tree: safariChromeTree(),
        family: .phone,
        probedElement: oversized
    )
    #expect(annotated["note"] == nil)
}

@Test
func rejectsAProbeResultWithNoUsableFrame() {
    let candidates: [[String: Any]] = [
        ["role": "StaticText"],
        ["role": "StaticText", "frame": ["x": 0, "y": 0, "w": 0, "h": 19]],
        ["role": "StaticText", "frame": "not a frame"]
    ]
    for element in candidates {
        let annotated = AXTreeAnnotator.annotate(
            tree: safariChromeTree(),
            family: .phone,
            probedElement: element
        )
        #expect(annotated["note"] == nil)
    }
}

@Test
func rejectsAProbeResultTheTreeAlreadyCarries() {
    // The guard against a hit-test answering with something the walk did
    // produce. Such a result proves the opposite of the note.
    let annotated = AXTreeAnnotator.annotate(
        tree: safariChromeTree(),
        family: .phone,
        probedElement: chromeButton(label: "Back", identifier: "BackButton", x: 34)
    )
    #expect(annotated["note"] == nil)
    #expect(annotated["noteCode"] == nil)
}

@Test(arguments: ["role", "identifier", "label", "frame"])
func identityComparesAllFourDedupKeyFields(differing field: String) {
    // Identity is `AXSweep.dedupKey`, not frame alone. Changing any one of
    // the four fields makes the probe result a different element, so the note
    // fires again.
    var element = chromeButton(label: "Back", identifier: "BackButton", x: 34)
    if field == "frame" {
        element["frame"] = ["x": 35, "y": 792, "w": 48, "h": 48]
    } else {
        element[field] = "changed"
    }
    let annotated = AXTreeAnnotator.annotate(
        tree: safariChromeTree(),
        family: .phone,
        probedElement: element
    )
    #expect(annotated["note"] as? String == expectedIncompleteNote)
}

@Test
func matchesAnEnumeratedElementAtAnyDepth() {
    // A nested node counts as enumerated just as a top-level one does.
    let leaf: [String: Any] = [
        "role": "Button",
        "label": "Nested Label",
        "frame": ["x": 10, "y": 710, "w": 40, "h": 40],
        "children": []
    ]
    let group: [String: Any] = [
        "role": "Group",
        "frame": ["x": 0, "y": 700, "w": 402, "h": 100],
        "children": [leaf]
    ]
    let probed: [String: Any] = [
        "role": "Button",
        "label": "Nested Label",
        "frame": ["x": 10, "y": 710, "w": 40, "h": 40]
    ]
    let annotated = AXTreeAnnotator.annotate(
        tree: rootTree(child: group),
        family: .phone,
        probedElement: probed
    )
    #expect(annotated["note"] == nil)
}

@Test
func aMalformedProbeResultDoesNotCollideWithAMalformedNode() {
    // `dedupKey` renders missing keys as empty, so an element with almost
    // nothing in it must not match a node with almost nothing in it by
    // accident. Here it is rejected earlier, on its unusable frame; the point
    // is that neither path produces a note.
    let annotated = AXTreeAnnotator.annotate(
        tree: rootTree(child: ["children": []]),
        family: .phone,
        probedElement: [:]
    )
    #expect(annotated["note"] == nil)
}

// MARK: - Precedence and family independence

@Test
func theWatchNoteWinsWhenBothRulesCouldApply() {
    // Both could hold only on a watch tree that enumerated nothing at all.
    // The watch note explains why there are no children anywhere, which is
    // strictly more than "the walk missed something".
    let tree: [String: Any] = [
        "role": "Application",
        "frame": ["x": 0, "y": 0, "w": 396, "h": 484],
        "children": []
    ]
    let probed: [String: Any] = [
        "role": "StaticText",
        "frame": ["x": 10, "y": 10, "w": 50, "h": 20]
    ]
    let annotated = AXTreeAnnotator.annotate(
        tree: tree,
        family: .watch,
        probedElement: probed
    )
    #expect(annotated["note"] as? String == expectedNote)
    #expect(annotated["noteCode"] as? String == expectedNoteCode)
}

@Test
func notesAnEmptyNonWatchTreeTheProbeContradicts() {
    // An empty tree on a phone is a legitimate state until hit-testing
    // proves an element was there.
    let tree: [String: Any] = [
        "role": "Application",
        "frame": ["x": 0, "y": 0, "w": 402, "h": 874],
        "children": []
    ]
    let annotated = AXTreeAnnotator.annotate(
        tree: tree,
        family: .phone,
        probedElement: safariPageText()
    )
    #expect(annotated["note"] as? String == expectedIncompleteNote)
}

@Test(arguments: DeviceFamily.allCases)
func theIncompletenessNoteIsNotFamilyGated(family: DeviceFamily) {
    // The evidence is a property of the observed screen, not the hardware,
    // and `.unknown` covers physical devices and future families where a
    // gate would do the most harm. The root carries children so the watch
    // rule cannot fire and steal the result.
    let annotated = AXTreeAnnotator.annotate(
        tree: safariChromeTree(),
        family: family,
        probedElement: safariPageText()
    )
    #expect(annotated["note"] as? String == expectedIncompleteNote)
}

@Test
func survivesMalformedChildren() {
    let tree: [String: Any] = [
        "role": "Application",
        "frame": ["x": 0, "y": 0, "w": 402, "h": 874],
        "children": ["a string", 7, [], ["role": "Button"]]
    ]
    #expect(AXTreeAnnotator.probePoint(for: tree, family: .phone) != nil)
    let annotated = AXTreeAnnotator.annotate(
        tree: tree,
        family: .phone,
        probedElement: nil
    )
    #expect(annotated["note"] == nil)
}
