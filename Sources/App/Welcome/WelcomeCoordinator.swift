// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import Observation

/// Owns when a welcome appears and records that it
/// did.
///
/// Splits cleanly from `WelcomeSelection`, which holds the rules: this
/// side supplies the state, performs the presentation, and latches
/// `didShowThisLaunch`.
///
/// The two pieces of state come from different places on purpose. The
/// `welcome-messages` master switch is a user preference, so it lives in
/// `~/.config/deviceterm/config`. The seen set is bookkeeping the app
/// writes, so it lives in the XDG cache via `WelcomeSeenStore` and stays
/// out of a file people hand-edit and keep in git.
///
/// That latch is read by `HeadlessAdvisoryViewModel`: a session where a
/// welcome already explained the coexistence model does not also get the
/// hazard alert. Stacking a modal on top of an explanation the user is
/// still reading is how both end up dismissed unread.
///
/// State reads/writes and the presentation itself are injected closures,
/// so the gate logic is testable without a window server: the production
/// `init()` wires the real config file and window controller.
@MainActor
@Observable
final class WelcomeCoordinator {
    /// Master opt-out key in `~/.config/deviceterm/config`: `suppress`
    /// hides every welcome, seen or not.
    static let suppressKey = "welcome-messages"

    /// Shared instance. The `didShowThisLaunch` latch is process-global,
    /// so every caller (launch, the Help menu, the advisory's gate)
    /// must route through the same coordinator.
    static let shared = WelcomeCoordinator()

    private static let defaultSeenReader: @MainActor () -> Set<String> = {
        WelcomeSeenStore().read()
    }

    private static let defaultSeenWriter: @MainActor (Set<String>) -> Void = { ids in
        WelcomeSeenStore().write(ids)
    }

    private static let defaultIsSuppressedReader: @MainActor () -> Bool = {
        ConfigFile().value(forKey: WelcomeCoordinator.suppressKey) == "suppress"
    }

    /// True once any welcome has been presented this launch, by either
    /// the automatic or the manual path. Observed by the advisory.
    private(set) var didShowThisLaunch = false

    /// True only while a **first-run** welcome is on screen. The launch
    /// sequence holds the first DeviceTerm window until that window
    /// closes, so anything that can open a window has to check this:
    /// otherwise a Dock click or ⌘N opens one behind the welcome and
    /// then the gate's completion opens a second.
    ///
    /// Deliberately false for an explicit reopen. That window carries no
    /// completion, so nothing is waiting to open a window behind it, and
    /// blocking New Window, New Tab, Settings, and Dock reopen would
    /// break normal behavior for no gain. That matters most when every
    /// window is already closed, where the Dock click is how the user
    /// gets one back.
    private(set) var isGatingLaunch = false

    private let catalog: [WelcomeMessage]
    private let seenReader: @MainActor () -> Set<String>
    private let seenWriter: @MainActor (Set<String>) -> Void
    private let isSuppressedReader: @MainActor () -> Bool

    /// Test seam. Nil in production, where `showWindow(for:)` runs
    /// instead. A test injects a recorder to observe which message was
    /// chosen and how it was presented, without needing a window server.
    /// The third parameter is the dismissal, so a test can leave the
    /// welcome "open" and exercise what happens while it is.
    private let injectedPresenter: (
        @MainActor (WelcomeMessage, WelcomePresentation, @escaping () -> Void) -> Void
    )?

    /// The one live welcome window, re-fronted rather than stacked on a
    /// repeat invocation. Mirrors how `AppDelegate` keeps a single
    /// `AboutWindowController`.
    private var windowController: WelcomeWindowController?

    /// Id of the welcome currently on screen, or nil when none is. Held
    /// separately from `windowController` so the test seam, which has no
    /// window, follows the same path as production.
    private var presentedMessageID: String?

    init(
        catalog: [WelcomeMessage] = WelcomeCatalog.messages,
        seen: @escaping @MainActor () -> Set<String> = WelcomeCoordinator.defaultSeenReader,
        recordSeen: @escaping @MainActor (Set<String>) -> Void = WelcomeCoordinator.defaultSeenWriter,
        isSuppressed: @escaping @MainActor () -> Bool = WelcomeCoordinator.defaultIsSuppressedReader,
        present: (
            @MainActor (WelcomeMessage, WelcomePresentation, @escaping () -> Void) -> Void
        )? = nil
    ) {
        self.catalog = catalog
        self.seenReader = seen
        self.seenWriter = recordSeen
        self.isSuppressedReader = isSuppressed
        self.injectedPresenter = present
    }

    /// Automatic path, called once at launch. Presents the first unseen
    /// welcome, or nothing when the catalog is exhausted, the master
    /// switch is off, or one already appeared this launch.
    /// - Parameter onFinished: run when the welcome is dismissed, or
    ///   immediately when there is nothing to show. The launch sequence
    ///   opens the first DeviceTerm window from here, so this has to
    ///   fire on every path or the app would run with no window.
    func presentIfNeeded(onFinished: @escaping () -> Void = {}) {
        let id = WelcomeSelection.next(
            catalog: catalog.map(\.id),
            seen: seenReader(),
            isSuppressed: isSuppressedReader(),
            shownThisLaunch: didShowThisLaunch
        )
        guard let id, let message = catalog.first(where: { $0.id == id }) else {
            onFinished()
            return
        }
        present(message, presentation: .firstRun, onFinished: onFinished)
    }

    /// Explicit path: the Help menu, and the advisory's Learn More…
    /// button. Deliberately bypasses both the seen set and the master
    /// switch, because the user asked for it, so "already read it" and
    /// "don't show me these" are not reasons to refuse. It still records
    /// the id and sets the latch, so a welcome opened this way also
    /// keeps the advisory quiet.
    func present(id: String) {
        guard let message = catalog.first(where: { $0.id == id }) else { return }
        present(message, presentation: .reopened, onFinished: {})
    }

    private func present(
        _ message: WelcomeMessage,
        presentation: WelcomePresentation,
        onFinished: @escaping () -> Void
    ) {
        // A repeat request for the message already on screen surfaces it
        // and changes nothing else. This returns before any state
        // mutation on purpose: choosing Help while the first-run welcome
        // is still open arrives here as `.reopened`, and letting that
        // reach the assignments below would clear a gate whose
        // completion is still pending, so New Window could then open one
        // window and Continue a second.
        if presentedMessageID == message.id {
            windowController?.showWelcome()
            return
        }

        didShowThisLaunch = true
        var seen = seenReader()
        if seen.insert(message.id).inserted {
            seenWriter(seen)
        }
        presentedMessageID = message.id
        // Describes the window about to appear, and changes again only
        // when that window closes. See `isGatingLaunch`.
        isGatingLaunch = presentation == .firstRun

        guard injectedPresenter == nil else {
            injectedPresenter?(message, presentation) { [weak self] in
                self?.finishPresentation()
                onFinished()
            }
            return
        }
        showWindow(for: message, presentation: presentation, onFinished: onFinished)
    }

    /// Build and show the message's window. The already-showing case is
    /// handled by the caller, so reaching here always creates one.
    private func showWindow(
        for message: WelcomeMessage,
        presentation: WelcomePresentation,
        onFinished: @escaping () -> Void
    ) {
        let controller = WelcomeWindowController(message: message, presentation: presentation)
        controller.onFinished = { [weak self] in
            self?.windowController = nil
            self?.finishPresentation()
            onFinished()
        }
        windowController = controller
        controller.showWelcome()
    }

    /// Clear the on-screen state when a welcome goes away. The gate ends
    /// here and nowhere else, which is what keeps a repeat presentation
    /// request from ending it early.
    private func finishPresentation() {
        presentedMessageID = nil
        isGatingLaunch = false
    }

    /// Surface the welcome that is already up. Used when something the
    /// user did would otherwise open a window behind it.
    func bringToFront() {
        windowController?.showWelcome()
    }
}
