// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Foundation
import SwiftUI
import Testing

/// The welcome registry's selection rules, including the "at most one per
/// launch" rule.
@MainActor
struct WelcomeSelectionTests {
    @Test
    func picksFirstUnseen() {
        let next = WelcomeSelection.next(
            catalog: ["a", "b"],
            seen: [],
            isSuppressed: false,
            shownThisLaunch: false
        )
        #expect(next == "a")
    }

    @Test
    func skipsSeenAndPicksTheNextOne() {
        let next = WelcomeSelection.next(
            catalog: ["a", "b"],
            seen: ["a"],
            isSuppressed: false,
            shownThisLaunch: false
        )
        #expect(next == "b")
    }

    @Test
    func nothingLeftWhenAllSeen() {
        let next = WelcomeSelection.next(
            catalog: ["a", "b"],
            seen: ["a", "b"],
            isSuppressed: false,
            shownThisLaunch: false
        )
        #expect(next == nil)
    }

    @Test
    func masterSwitchHidesEvenUnseenMessages() {
        // `welcome-messages = suppress` means "none of these", not
        // "none of the ones I've read".
        let next = WelcomeSelection.next(
            catalog: ["a"],
            seen: [],
            isSuppressed: true,
            shownThisLaunch: false
        )
        #expect(next == nil)
    }

    @Test
    func atMostOnePerLaunchEvenWithSeveralUnseen() {
        // The rule the mechanism exists for: two explanatory windows on
        // one launch trains the user to dismiss without reading, which
        // costs more than deferring the second by a launch.
        let next = WelcomeSelection.next(
            catalog: ["a", "b"],
            seen: [],
            isSuppressed: false,
            shownThisLaunch: true
        )
        #expect(next == nil)
    }
}

/// The seen cache's storage format.
@MainActor
struct WelcomeSeenStoreTests {
    @Test
    func parsesOneIdPerLineIgnoringBlanks() {
        // Hand-editing is expected (deleting a line re-arms a welcome),
        // so stray whitespace and blank lines can't corrupt the set.
        let parsed = WelcomeSeenStore.parse("a\n\n  b  \n\n")
        #expect(parsed == ["a", "b"])
    }

    @Test
    func parsesEmptyFileAsNothingSeen() {
        #expect(WelcomeSeenStore.parse("").isEmpty)
    }

    @Test
    func formatIsSortedAndNewlineTerminated() {
        // Sorted so rewriting an unchanged set leaves the file byte
        // identical rather than reordering on every launch.
        #expect(WelcomeSeenStore.format(["b", "a"]) == "a\nb\n")
    }

    @Test
    func roundTripsThroughDisk() {
        let path = NSTemporaryDirectory() + "deviceterm-welcome-seen-\(UUID().uuidString)/seen"
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let store = WelcomeSeenStore(path: path)

        #expect(store.read().isEmpty, "an absent file reads as nothing seen")
        store.write(["simulator-coexistence"])
        #expect(store.read() == ["simulator-coexistence"])
    }

    @Test
    func missingParentDirectoryIsCreated() {
        // The XDG cache dir may not exist on a fresh machine, so the
        // first write has to make it rather than silently dropping.
        let root = NSTemporaryDirectory() + "deviceterm-welcome-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = WelcomeSeenStore(path: root + "/nested/seen")
        store.write(["a"])
        #expect(store.read() == ["a"])
    }
}

/// Coordinator behavior, including the latch the advisory reads.
///
/// Presentation needs a window server, so the coordinator is driven with an
/// injected presenter that records which message it was handed.
@MainActor
struct WelcomeCoordinatorTests {
    private static func message(_ id: String) -> WelcomeMessage {
        WelcomeMessage(id: id, title: id, content: { _, _ in AnyView(EmptyView()) })
    }

    /// Coordinator over an in-memory seen set with a recording
    /// presenter, so nothing touches disk or the window server.
    private static func makeCoordinator(
        catalog: [WelcomeMessage],
        seen: Set<String> = [],
        isSuppressed: Bool = false,
        shown: @escaping @MainActor (WelcomeMessage, WelcomePresentation, @escaping () -> Void) -> Void
    ) -> (WelcomeCoordinator, () -> Set<String>) {
        var stored = seen
        let coordinator = WelcomeCoordinator(
            catalog: catalog,
            seen: { stored },
            recordSeen: { stored = $0 },
            isSuppressed: { isSuppressed },
            present: shown
        )
        return (coordinator, { stored })
    }

    @Test
    func presentsFirstUnseenAndRecordsIt() {
        var presented: [String] = []
        let (coordinator, seen) = Self.makeCoordinator(
            catalog: [Self.message("a"), Self.message("b")],
            shown: { message, _, finish in presented.append(message.id); finish() }
        )
        coordinator.presentIfNeeded()
        #expect(presented == ["a"])
        #expect(seen() == ["a"])
        #expect(coordinator.didShowThisLaunch)
    }

    @Test
    func presentsNothingASecondTimeInTheSameLaunch() {
        // Two unseen messages, one launch: the second waits.
        var presented: [String] = []
        let (coordinator, _) = Self.makeCoordinator(
            catalog: [Self.message("a"), Self.message("b")],
            shown: { message, _, finish in presented.append(message.id); finish() }
        )
        coordinator.presentIfNeeded()
        coordinator.presentIfNeeded()
        #expect(presented == ["a"])
    }

    @Test
    func suppressedByMasterSwitch() {
        var presented: [String] = []
        let (coordinator, seen) = Self.makeCoordinator(
            catalog: [Self.message("a")],
            isSuppressed: true,
            shown: { message, _, finish in presented.append(message.id); finish() }
        )
        coordinator.presentIfNeeded()
        #expect(presented.isEmpty)
        #expect(seen().isEmpty, "a welcome that never appeared isn't recorded as seen")
        #expect(!coordinator.didShowThisLaunch)
    }

    @Test
    func manualOpenIgnoresSeenAndSuppression() {
        // The Help menu is the way back to a welcome, so "already read
        // it" and "don't show me these" are not reasons to refuse.
        var presented: [String] = []
        let (coordinator, _) = Self.makeCoordinator(
            catalog: [Self.message("a")],
            seen: ["a"],
            isSuppressed: true,
            shown: { message, _, finish in presented.append(message.id); finish() }
        )
        coordinator.present(id: "a")
        #expect(presented == ["a"])
    }

    @Test
    func manualOpenAlsoSetsTheLatch() {
        // The advisory reads this latch. Opening the welcome by hand
        // has to keep an alert from landing on top of it.
        var presented: [String] = []
        let (coordinator, _) = Self.makeCoordinator(
            catalog: [Self.message("a")],
            seen: ["a"],
            shown: { message, _, finish in presented.append(message.id); finish() }
        )
        coordinator.present(id: "a")
        #expect(coordinator.didShowThisLaunch)
    }

    @Test
    func launchGateIsPresentedAsFirstRun() {
        // Drives the button verb and the footnote. The first-run screen
        // says "Continue" because dismissing it is what opens the app's
        // first window, and it tells the reader where to find this again.
        var recorded: [WelcomePresentation] = []
        let (coordinator, _) = Self.makeCoordinator(
            catalog: [Self.message("a")],
            shown: { _, presentation, finish in recorded.append(presentation); finish() }
        )
        coordinator.presentIfNeeded()
        #expect(recorded == [.firstRun])
    }

    @Test
    func manualOpenIsPresentedAsReopened() {
        // The Help menu path has nothing to continue to, and pointing a
        // reader who just used the Help menu back at it is noise.
        var recorded: [WelcomePresentation] = []
        let (coordinator, _) = Self.makeCoordinator(
            catalog: [Self.message("a")],
            shown: { _, presentation, finish in recorded.append(presentation); finish() }
        )
        coordinator.present(id: "a")
        #expect(recorded == [.reopened])
    }

    @Test("only the first-run presentation gates the launch", arguments: [
        (WelcomePresentation.firstRun, true),
        (WelcomePresentation.reopened, false)
    ])
    func gatesLaunchOnlyOnFirstRun(
        presentation: WelcomePresentation,
        expectedGating: Bool
    ) {
        // `AppDelegate` blocks New Window, New Tab, Settings, and Dock
        // reopen while this is set. An explicit reopen carries no
        // completion, so nothing is waiting to open a window behind it
        // and gating on it would break those for no reason, including
        // when it happens with every window already closed.
        var coordinatorRef: WelcomeCoordinator?
        var gatingWhileShown: Bool?
        let coordinator = WelcomeCoordinator(
            catalog: [Self.message("a")],
            seen: { [] },
            recordSeen: { _ in },
            isSuppressed: { false },
            present: { _, _, finish in
                gatingWhileShown = coordinatorRef?.isGatingLaunch
                finish()
            }
        )
        coordinatorRef = coordinator

        switch presentation {
        case .firstRun:
            coordinator.presentIfNeeded()

        case .reopened:
            coordinator.present(id: "a")
        }
        #expect(gatingWhileShown == expectedGating)
    }

    @Test
    func helpReopenDoesNotClearAnActiveLaunchGate() {
        // Choosing Help while the first-run welcome is still open
        // arrives as `.reopened` for a message already on screen. It
        // must surface that window and change nothing: the gate's
        // completion is still pending, and clearing the flag would let
        // New Window open one window and Continue open a second.
        var coordinatorRef: WelcomeCoordinator?
        var presentedCount = 0
        var windowOpened = 0
        let coordinator = WelcomeCoordinator(
            catalog: [Self.message("a")],
            seen: { [] },
            recordSeen: { _ in },
            isSuppressed: { false },
            // Never finishes: models a welcome the user hasn't dismissed.
            present: { _, _, _ in presentedCount += 1 }
        )
        coordinatorRef = coordinator

        coordinator.presentIfNeeded { windowOpened += 1 }
        #expect(coordinatorRef?.isGatingLaunch == true)

        coordinator.present(id: "a")
        #expect(coordinator.isGatingLaunch, "a re-front must not end the gate")
        #expect(presentedCount == 1, "the same message is surfaced, not presented twice")
        #expect(windowOpened == 0, "the gate's completion stays pending")
    }

    @Test
    func unknownIdIsIgnored() {
        // An unknown explicit message id, which a renamed Help action or
        // Learn More… target would pass, must not crash or present some
        // other message.
        var presented: [String] = []
        let (coordinator, _) = Self.makeCoordinator(
            catalog: [Self.message("a")],
            shown: { message, _, finish in presented.append(message.id); finish() }
        )
        coordinator.present(id: "gone")
        #expect(presented.isEmpty)
        #expect(!coordinator.didShowThisLaunch)
    }
}

/// The welcome ids, which are a contract in two directions: written into
/// the seen cache, and used by the Help menu.
@MainActor
struct WelcomeCatalogTests {
    @Test
    func idsAreStable() {
        // Ids are written into the seen cache. Renaming one re-shows
        // that welcome to everybody who already dismissed it.
        #expect(WelcomeCatalog.simulatorCoexistenceID == "simulator-coexistence")
        #expect(WelcomeCatalog.messages.map(\.id) == ["simulator-coexistence"])
    }

    @Test
    func everyMessageIsResolvableById() {
        for message in WelcomeCatalog.messages {
            #expect(WelcomeCatalog.message(for: message.id)?.id == message.id)
        }
        #expect(WelcomeCatalog.message(for: "no-such-welcome") == nil)
    }

    @Test
    func masterSwitchIsARecognizedConfigKey() {
        // The on/off switch is a preference and lives in the config
        // file; the seen set is app-written state and deliberately does
        // not, so it must not appear in the canonical table.
        #expect(WelcomeCoordinator.suppressKey == "welcome-messages")
        #expect(DeviceTermConfigDefaults.isKnown(WelcomeCoordinator.suppressKey))
        #expect(!DeviceTermConfigDefaults.isKnown("welcome-seen"))
    }
}
