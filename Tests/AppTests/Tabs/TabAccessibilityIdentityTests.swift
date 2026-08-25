// SPDX-License-Identifier: GPL-3.0-or-later
//
// The tab-strip identifiers are an observability contract with out-of-process
// accessibility consumers: filter the shared prefix to collect the controls,
// compare a full identifier against what `tabs list --json` reports. It is a
// join key with the CLI rather than a durable handle, since it names a tab's
// current primary session and follows a change of primary terminal.
//
// Uniqueness carries the weight here. A pill's title comes from a precedence
// chain that sibling tabs routinely resolve to the same string; the identifier
// is the only thing that names one, and a collision would put a consumer back
// where it started.
//
// The accessibility-element test covers the other half of the contract: an
// identifier is only reachable if the view carrying it is published to the
// accessibility tree at all, and the "+" is an NSControl with no cell, which
// publishes nothing unless it says so.

@testable import App
import AppKit
import Testing

/// Target for the accessibility-press test. `@objc` so `sendAction` can
/// dispatch to it the way the mouse path does.
@MainActor
private final class PressRecorder: NSObject {
    var presses = 0

    @objc
    func press(_ sender: Any?) {
        presses += 1
    }
}

@MainActor
struct TabAccessibilityIdentityTests {
    @Test
    func aTabAndItsCloserSpellThemselvesOut() {
        #expect(TabAccessibilityIdentity.identifier(forTab: "e0fy9r") == "deviceterm.tab.e0fy9r")
        #expect(
            TabAccessibilityIdentity.closeIdentifier(forTab: "e0fy9r")
                == "deviceterm.tab.e0fy9r.close"
        )
        #expect(TabAccessibilityIdentity.newTabButton == "deviceterm.tab.new")
    }

    @Test
    func everyIdentifierSharesThePrefix() {
        // A control without the prefix drops out of a prefix-filtered
        // collection, though it is still present in the tree.
        let identifiers = [
            TabAccessibilityIdentity.identifier(forTab: "abc123"),
            TabAccessibilityIdentity.closeIdentifier(forTab: "abc123"),
            TabAccessibilityIdentity.newTabButton
        ]
        for identifier in identifiers {
            #expect(identifier.hasPrefix(TabAccessibilityIdentity.prefix + "."))
        }
    }

    @Test
    func aPillItsCloserAndThePlusAreAllDistinct() {
        // All three sit side by side in one dump. Two that matched would make
        // "press the tab" and "press its ✕" the same instruction.
        let pill = TabAccessibilityIdentity.identifier(forTab: "abc123")
        let closer = TabAccessibilityIdentity.closeIdentifier(forTab: "abc123")
        #expect(pill != closer)
        #expect(pill != TabAccessibilityIdentity.newTabButton)
        #expect(closer != TabAccessibilityIdentity.newTabButton)
    }

    @Test
    func distinctTabsGetDistinctIdentifiers() {
        #expect(
            TabAccessibilityIdentity.identifier(forTab: "aaa111")
                != TabAccessibilityIdentity.identifier(forTab: "bbb222")
        )
    }

    @Test
    func theCloserIsDerivedFromItsPill() {
        // Suffixing keeps a prefix filter finding a tab and its closer
        // together, and a fixed six-character short id is what keeps the
        // suffixed form from reading as some other tab's pill.
        let pill = TabAccessibilityIdentity.identifier(forTab: "abc123")
        #expect(TabAccessibilityIdentity.closeIdentifier(forTab: "abc123") == pill + ".close")
    }

    @Test
    func stampingNamesBothTheTabAndItsCloser() {
        let pill = NSButton()
        let close = NSButton()
        TabStripViewController.applyAccessibilityIdentifiers(
            pill: pill, close: close, shortId: "abc123"
        )
        #expect(pill.accessibilityIdentifier() == "deviceterm.tab.abc123")
        #expect(close.accessibilityIdentifier() == "deviceterm.tab.abc123.close")
    }

    @Test
    func stampingClearsRatherThanLeavingAStaleName() {
        // The strip restamps in place, so clearing has to actually clear: a
        // leftover identifier would still answer a lookup and name a session
        // that no longer backs the tab.
        let pill = NSButton()
        let close = NSButton()
        TabStripViewController.applyAccessibilityIdentifiers(
            pill: pill, close: close, shortId: "abc123"
        )
        TabStripViewController.applyAccessibilityIdentifiers(
            pill: pill, close: close, shortId: nil
        )
        #expect(pill.accessibilityIdentifier().isEmpty)
        #expect(close.accessibilityIdentifier().isEmpty)
    }

    @Test
    func stampingRenamesWhenThePrimaryTerminalChanges() {
        let pill = NSButton()
        let close = NSButton()
        TabStripViewController.applyAccessibilityIdentifiers(
            pill: pill, close: close, shortId: "aaa111"
        )
        TabStripViewController.applyAccessibilityIdentifiers(
            pill: pill, close: close, shortId: "bbb222"
        )
        #expect(pill.accessibilityIdentifier() == "deviceterm.tab.bbb222")
        #expect(close.accessibilityIdentifier() == "deviceterm.tab.bbb222.close")
    }

    @Test
    func thePlusDispatchesItsActionOnAnAccessibilityPress() {
        // Being visible in a dump is not the same as being drivable. With no
        // NSButtonCell there is nothing to turn a press into target/action,
        // so this is what makes the accessibility path dispatch the same
        // action the mouse path sends.
        let recorder = PressRecorder()
        let button = NewTabButton()
        button.target = recorder
        button.action = #selector(PressRecorder.press(_:))

        #expect(button.accessibilityPerformPress())
        #expect(recorder.presses == 1)
    }

    @Test
    func aPlusWithNoActionReportsThePressAsUnhandled() {
        // Nothing can be dispatched without an action, and saying otherwise
        // would let a caller read success as "a tab opened". A nil *target*
        // is a different case: with an action set, AppKit dispatches it
        // through the responder chain.
        #expect(!NewTabButton().accessibilityPerformPress())
    }

    @Test
    func thePlusPublishesItselfToTheAccessibilityTree() {
        // AppKit prunes a view that is not an accessibility element, and this
        // one subclasses NSControl without a cell, so nothing about it is
        // vended by default: not the role, not the label, not the identifier,
        // and not the plus image it contains. Assistive technology and any
        // out-of-process consumer both depend on this opt-in.
        let button = NewTabButton()
        #expect(button.isAccessibilityElement())
        #expect(button.accessibilityRole() == .button)
        #expect(button.accessibilityLabel() == "New Tab")
        #expect(button.accessibilityIdentifier() == TabAccessibilityIdentity.newTabButton)
    }
}
