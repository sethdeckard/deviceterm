// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import AppKit
import DaemonProtocol
import Testing

/// The keybinding drift guard, run in both directions: every catalog
/// entry appears in the menu, and every bound menu item appears in the
/// catalog, with multiplicities compared so a duplicate is caught too.
///
/// The pinned map below is deliberately a literal table, so a change to
/// any shortcut shows up in review as a readable diff rather than as a
/// behavioral surprise.
@MainActor
struct KeybindingCatalogTests {
    /// Identity of a bound menu item, for set comparison against the catalog.
    private struct BoundItem: Hashable {
        let title: String
        let chord: KeyChord
        let selector: String
        let tag: Int
    }

    /// Menus populated by an `NSMenuDelegate` are empty at construction time,
    /// so the walk below cannot see inside them. Each one is named here
    /// deliberately; an unregistered delegate-bearing menu fails the
    /// registration test rather than silently escaping coverage.
    private static let dynamicMenuTitles: Set<String> = ["Location"]

    /// Whether `cls` implements `selector` on itself rather than
    /// inheriting it. `class_copyMethodList` reports one class's own
    /// methods, which is the distinction the scope check turns on.
    private static func declaresItsOwn(_ cls: AnyClass, _ selector: Selector) -> Bool {
        var count: UInt32 = 0
        guard let methods = class_copyMethodList(cls, &count) else { return false }
        defer { free(methods) }
        for index in 0..<Int(count) where method_getName(methods[index]) == selector {
            return true
        }
        return false
    }

    private static func keyEvent(
        type: NSEvent.EventType,
        characters: String,
        flags: NSEvent.ModifierFlags
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 0
        )
    }

    private func boundItems(in menu: NSMenu) -> [BoundItem] {
        var found: [BoundItem] = []
        for item in menu.items {
            if !item.keyEquivalent.isEmpty, let chord = KeyChord(menuItem: item) {
                found.append(
                    BoundItem(
                        title: item.title,
                        chord: chord,
                        selector: item.action.map(NSStringFromSelector) ?? "",
                        tag: item.tag
                    )
                )
            }
            if let submenu = item.submenu {
                found.append(contentsOf: boundItems(in: submenu))
            }
        }
        return found
    }

    private func catalogItems() -> [BoundItem] {
        KeybindingCatalog.entries.map {
            BoundItem(
                title: $0.title,
                chord: $0.chord,
                selector: NSStringFromSelector($0.selector),
                tag: $0.tag
            )
        }
    }

    // MARK: - 1. Catalog covers the action enum, exactly once each

    @Test
    func catalogCoversEveryActionExactlyOnce() {
        let actions = KeybindingCatalog.entries.map(\.action)
        #expect(Set(actions) == Set(KeybindingAction.allCases))
        #expect(actions.count == KeybindingAction.allCases.count, "duplicate action in catalog")
    }

    // MARK: - 2. Menu ↔ catalog, both directions

    @Test
    func everyCatalogEntryAppearsInTheMenu() {
        let inMenu = Set(boundItems(in: makeMainMenu()))
        for entry in catalogItems() {
            #expect(
                inMenu.contains(entry),
                "\(entry.chord.displayString) '\(entry.title)' is in the catalog but not in any menu"
            )
        }
    }

    @Test
    func everyMenuKeyEquivalentComesFromTheCatalog() {
        let inCatalog = Set(catalogItems())
        for item in boundItems(in: makeMainMenu()) {
            #expect(
                inCatalog.contains(item),
                "\(item.chord.displayString) '\(item.title)' is bound in the menu but absent from the catalog"
            )
        }
    }

    @Test
    func theMenuBindsEachCatalogEntryExactlyOnce() {
        // Set membership alone would let a second, identical copy of a bound
        // item slip through: a duplicate that AppKit would show twice and
        // whose shortcut would be ambiguous to read. Compare multiplicities,
        // not just membership.
        let menuCounts = boundItems(in: makeMainMenu()).reduce(into: [BoundItem: Int]()) {
            $0[$1, default: 0] += 1
        }
        let catalogCounts = catalogItems().reduce(into: [BoundItem: Int]()) {
            $0[$1, default: 0] += 1
        }
        let menuTotal = menuCounts.values.reduce(0, +)
        let catalogTotal = catalogCounts.values.reduce(0, +)
        #expect(
            menuTotal == catalogTotal,
            "menu has \(menuTotal) bound items for \(catalogTotal) catalog rows"
        )
        for (item, count) in menuCounts where count != catalogCounts[item] {
            let expected = catalogCounts[item] ?? 0
            let message: String = "\(item.chord.displayString) '\(item.title)' appears "
                + "\(count)× in the menu but \(expected)× in the catalog"
            Issue.record("\(message)")
        }
    }

    // MARK: - 3. The pinned map

    @Test
    func theBindingMapIsUnchanged() {
        let pinned: [(KeybindingAction, String)] = [
            (.openSettings, "⌘,"),
            (.hideApp, "⌘H"),
            (.hideOthers, "⌥⌘H"),
            (.quit, "⌘Q"),
            (.newWindow, "⌘N"),
            (.newTab, "⌘T"),
            (.openAutomationTab, "⇧⌘T"),
            (.closePane, "⌘W"),
            (.closeTab, "⌥⌘W"),
            (.closeWindow, "⇧⌘W"),
            (.minimize, "⌘M"),
            (.cut, "⌘X"),
            (.copy, "⌘C"),
            (.paste, "⌘V"),
            (.selectAll, "⌘A"),
            (.clearBuffer, "⌘K"),
            (.selectTab1, "⌘1"),
            (.selectTab2, "⌘2"),
            (.selectTab3, "⌘3"),
            (.selectTab4, "⌘4"),
            (.selectTab5, "⌘5"),
            (.selectTab6, "⌘6"),
            (.selectTab7, "⌘7"),
            (.selectTab8, "⌘8"),
            (.selectLastTab, "⌘9"),
            (.selectPreviousTab, "⇧⌘["),
            (.selectNextTab, "⇧⌘]"),
            (.splitRight, "⌘D"),
            (.splitDown, "⇧⌘D"),
            (.selectPreviousPane, "⌘["),
            (.selectNextPane, "⌘]"),
            (.selectPaneAbove, "⌥⌘↑"),
            (.selectPaneBelow, "⌥⌘↓"),
            (.selectPaneLeft, "⌥⌘←"),
            (.selectPaneRight, "⌥⌘→"),
            (.movePaneLeft, "⇧⌘←"),
            (.movePaneRight, "⇧⌘→"),
            (.moveTabLeft, "⌃⇧←"),
            (.moveTabRight, "⌃⇧→"),
            (.toggleSplitDirection, "⌃⇧D"),
            (.zoomIn, "⌘="),
            (.zoomOut, "⌘-"),
            (.resetZoom, "⌘0"),
            (.toggleFullScreen, "⌃⌘F"),
            (.toggleAxInspector, "⌥⌘A"),
            (.deviceHome, "⇧⌘H"),
            (.deviceLock, "⌘L"),
            (.deviceRotateLeft, "⌘←"),
            (.deviceRotateRight, "⌘→"),
            (.deviceScreenshot, "⌘S"),
            (.deviceRecord, "⌘R"),
            (.sizePresetPhysical, "⌃⌘1"),
            (.sizePresetPointAccurate, "⌃⌘2"),
            (.sizePresetPixelAccurate, "⌃⌘3"),
            (.sizePresetFitScreen, "⌃⌘4")
        ]
        let actual = KeybindingCatalog.entries.map { ($0.action, $0.chord.displayString) }
        #expect(actual.count == pinned.count, "binding count changed: \(actual.count) vs \(pinned.count)")
        for (index, expected) in pinned.enumerated() where index < actual.count {
            #expect(actual[index].0 == expected.0, "row \(index): action differs")
            #expect(actual[index].1 == expected.1, "row \(index) (\(expected.0)): chord differs")
        }
    }

    // MARK: - 3b. Numbered tabs agree with their tags

    @Test
    func numberedTabItemsCarryTheTagTheirTitleClaims() {
        // Eight near-identical rows sharing one selector and differing only
        // by `tag` is exactly the shape a copy-paste slip survives: the
        // menu↔catalog checks would still pass with "Tab 3" carrying tag 5,
        // because both sides would agree on the wrong value. Tie the tag to
        // the visible label instead, which is what the user reads.
        for number in 1...8 {
            guard let entry = KeybindingCatalog.entries.first(
                where: { $0.title == "Tab \(number)" }
            ) else {
                Issue.record("catalog has no Tab \(number)")
                continue
            }
            #expect(entry.tag == number, "Tab \(number) carries tag \(entry.tag)")
            #expect(entry.chord.keyEquivalent == "\(number)")
        }
        // Last Tab addresses the end of the strip, so it deliberately has
        // no position tag to agree with.
        let lastTab = KeybindingCatalog.entry(for: .selectLastTab)
        #expect(lastTab?.tag == 0)
    }

    // MARK: - 4. Modifier invariant

    @Test
    func everyChordCarriesCommandOrControlShift() {
        // Bare-Option chords never reach AppKit's key-equivalent matching at
        // all, so they are silently dead. Option is also the terminal's Meta
        // and compose modifier. Every chord therefore carries ⌘, or ⌃⇧.
        for entry in KeybindingCatalog.entries {
            let mods = entry.chord.modifiers
            let ok = mods.contains(.command) || mods.isSuperset(of: [.control, .shift])
            #expect(ok, "\(entry.chord.displayString) (\(entry.action)) is neither ⌘- nor ⌃⇧-based")
        }
    }

    // MARK: - 5. No duplicate chord

    @Test
    func noTwoActionsShareAChord() {
        var seen: [KeyChord: KeybindingAction] = [:]
        for entry in KeybindingCatalog.entries {
            if let existing = seen[entry.chord] {
                Issue.record("\(entry.chord.displayString) is bound to both \(existing) and \(entry.action)")
            }
            seen[entry.chord] = entry.action
        }
    }

    // MARK: - 6. Responder reachability

    @Test
    func everyDeclaredResponderImplementsItsSelector() {
        // Class-level introspection over the responders each entry declares,
        // so the test needs no live responder chain. It catches a selector
        // rename or a missing implementation on a declared responder. It does
        // not verify that a class omitted from `responders` should have been
        // listed, nor that these classes sit in the chain at runtime.
        for entry in KeybindingCatalog.entries {
            #expect(!entry.responders.isEmpty, "\(entry.action) declares no responders")
            for responder in entry.responders {
                // Hoisted out of `#expect`: the macro rewrites a call on a
                // metatype into an instance call and fails to compile.
                let responds = responder.instancesRespond(to: entry.selector)
                #expect(
                    responds,
                    "\(responder) does not implement \(NSStringFromSelector(entry.selector)) for \(entry.action)"
                )
            }
        }
    }

    // MARK: - 7. Key equivalents are lowercase

    @Test
    func keyEquivalentsAreAlwaysLowercase() {
        // AppKit reads an uppercase "T" as ⇧+"t", so a chord carrying shift
        // in the string would disagree with its own modifier mask.
        for entry in KeybindingCatalog.entries {
            let equivalent = entry.chord.keyEquivalent
            #expect(
                equivalent == equivalent.lowercased(),
                "\(entry.action) has a non-lowercase key equivalent"
            )
        }
    }

    // MARK: - 7b. Scope agrees with what the selector targets

    @Test
    func everyDeviceTargetedEntryIsScopedToTheDevicePane() {
        // Scope and target have to agree in both directions. A device
        // control left at `.app` would rotate a sim the user is not
        // looking at, and an app action marked `.devicePane` would read
        // disabled for no reason a user could explain.
        //
        // Ground truth is whether `SimulatorPaneViewController` declares
        // the selector *itself*. `instancesRespond(to:)` would answer for
        // inherited methods too, so an app action naming a selector that
        // any `NSResponder` vends would read as device-targeted.
        for entry in KeybindingCatalog.entries {
            let targetsDevice = Self.declaresItsOwn(
                SimulatorPaneViewController.self,
                entry.selector
            )
            #expect(
                (entry.scope == .devicePane) == targetsDevice,
                "\(entry.action) is \(entry.scope) but targets device pane: \(targetsDevice)"
            )
        }
    }

    // MARK: - 7c. The device pane's HID guard

    @Test
    func aBoundControlShiftChordIsClaimedAwayFromTheGuest() throws {
        // `SimulatorContentView` asks `claims(_:)` before forwarding a
        // keystroke to the device as HID. ⌃⇧D carries no Command, so the
        // Command test alone would type Toggle Split Direction into the
        // guest whenever its menu item validated disabled.
        //
        // The synthesized readings are what this matches on, so the
        // assertion does not depend on the active keyboard layout the way
        // a re-derived `characters(byApplyingModifiers:)` would.
        let event = try #require(
            Self.keyEvent(type: .keyDown, characters: "d", flags: [.control, .shift])
        )
        #expect(KeybindingCatalog.claims(event))
    }

    @Test
    func anUnboundKeystrokeIsLeftToTheGuest() throws {
        // The guard has to subtract only what the catalog owns. Claiming
        // an ordinary letter would leave the device unable to receive
        // typing at all.
        let event = try #require(Self.keyEvent(type: .keyDown, characters: "z", flags: []))
        #expect(!KeybindingCatalog.claims(event))
    }

    @Test
    func aKeyUpIsClaimedToo() throws {
        // The device pane forwards on both edges, so a chord claimed on
        // the way down and released on the way up would send a stray key
        // release into the guest.
        let event = try #require(
            Self.keyEvent(type: .keyUp, characters: "d", flags: [.control, .shift])
        )
        #expect(KeybindingCatalog.claims(event))
    }

    // MARK: - 8. Dynamic submenus are declared, not discovered

    @Test
    func everyDelegatePopulatedSubmenuIsDeclared() {
        // A menu built by `menuNeedsUpdate` is empty when the walk above runs,
        // so it cannot be covered by the bidirectional check. Requiring each
        // one to be named here means adding a dynamic submenu cannot silently
        // opt out of shortcut coverage.
        func check(_ menu: NSMenu) {
            for item in menu.items {
                guard let submenu = item.submenu else { continue }
                if submenu.delegate != nil {
                    #expect(
                        Self.dynamicMenuTitles.contains(item.title),
                        "'\(item.title)' is delegate-populated but not declared in dynamicMenuTitles"
                    )
                }
                check(submenu)
            }
        }
        check(makeMainMenu())
    }

    @Test
    func everyDynamicLocationRowShapeCarriesNoKeyEquivalent() {
        // Location rows are built at open time, so the menu walk above cannot
        // see them. Direct rendering covers every row case without depending
        // on a live pane and its current model. Location rows intentionally
        // have no shortcuts, and a row that grew one would otherwise be
        // invisible.
        let controller = LocationMenuController { nil }
        let rows: [LocationMenuRow] = [
            .separator,
            .header(title: "Saved"),
            .location(title: "Home", location: .coordinate(latitude: 1, longitude: 2), isActive: true),
            .location(title: "Apple Park", location: .scenario(name: "City Run"), isActive: false),
            .route(title: "Commute", path: "/tmp/commute.gpx", isActive: true),
            .useMyLocation,
            .customCoordinates
        ]
        for row in rows {
            let item = controller.item(for: row)
            #expect(
                item.keyEquivalent.isEmpty,
                "dynamic Location row '\(item.title)' carries a key equivalent"
            )
        }
    }

    @Test
    func theLocationDelegateProducesRowsWithNoPane() throws {
        // The no-pane path is the one shape the delegate can build without a
        // live view model, and it must still be shortcut-free.
        let item = makeLocationMenuItem { nil }
        let submenu = try #require(item.submenu)
        let delegate = try #require(submenu.delegate)
        delegate.menuNeedsUpdate?(submenu)
        #expect(!submenu.items.isEmpty, "delegate produced no rows; the assertion below would be vacuous")
        for row in submenu.items {
            #expect(row.keyEquivalent.isEmpty, "Location fallback row '\(row.title)' carries a key equivalent")
        }
    }
}
