// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import AppKit
import Observation
import Testing

/// Stand-in for the tab or pane a prompt is asking about. `@Observable`
/// so the watch tracks it the same way it tracks a `TabListViewModel`.
@MainActor
@Observable
private final class FakeTarget {
    var exists = true
}

/// Where a prompt's answer lands, so a test can wait for it with a
/// bound instead of awaiting the task.
@MainActor
private final class Answer<Value> {
    var value: Value?
}

/// Mutable state shared with a dismissal closure.
/// `CloseSheetLifetime.Dismiss` is `@MainActor` and therefore Sendable,
/// so a plain local `var` cannot be written by the test after the
/// closure captures it.
@MainActor
private final class Cell<Value> {
    var value: Value

    init(_ value: Value) { self.value = value }
}

/// A temp config the prompt reads, plus the in-memory suppression tiers
/// it would write to. Both start empty so the prompt presents.
@MainActor
private struct Fixture {
    let path: String
    let config: ConfigFile
    let state: CloseSuppressionState
}

/// A close prompt takes itself down when the
/// thing it is asking about stops existing.
///
/// Two suites, because the claims need different machinery. The watch
/// itself is pure enough to drive with a fake `@Observable` target. The
/// claim that actually matters to a user, that a real sheet comes off a
/// real window and the awaiting caller gets exactly one answer, needs
/// AppKit and so gets the `.serialized` treatment
/// `CustomCoordinatesSheetPresentationTests` already established.
///
/// Nothing here awaits a prompt's task. These tests provoke the exact
/// failure that leaves a checked continuation unresumed, and awaiting one
/// would wedge the whole run rather than fail one test, so every wait is
/// bounded and every answer is read out of a box.
@MainActor
struct CloseSheetLifetimeTests {
    /// Let the watch's re-arm hop through the main actor. `observe`
    /// re-arms on the next turn rather than synchronously, so a change
    /// made in this turn is not seen until the loop has run. Long
    /// enough to span several `retryInterval`s, since the paced retry
    /// is slower than a plain re-arm.
    private func settle() async {
        for _ in 0..<40 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// Wait for `condition`, bounded. Preferred over `settle()` wherever
    /// there is something to wait for: the paced retry means a fixed
    /// sleep is either slow or flaky.
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    @Test
    func aLiveTargetIsLeftAlone() async {
        let target = FakeTarget()
        var dismissals = 0
        let lifetime = CloseSheetLifetime(
            isTargetAlive: { target.exists },
            dismiss: { dismissals += 1; return true }
        )
        lifetime.start()
        await settle()
        #expect(dismissals == 0)
        lifetime.finish()
    }

    @Test
    func removingTheTargetDismissesTheSheet() async {
        let target = FakeTarget()
        var dismissals = 0
        let lifetime = CloseSheetLifetime(
            isTargetAlive: { target.exists },
            dismiss: { dismissals += 1; return true }
        )
        lifetime.start()
        await settle()

        target.exists = false
        await settle()

        #expect(dismissals == 1)
        lifetime.finish()
    }

    /// A target already gone when the watch arms still dismisses. The
    /// sheet is presented before the watch starts, so this is the state
    /// a removal landing in that gap leaves behind, and a watch that
    /// only reacted to changes would sit on it forever.
    @Test
    func aTargetAlreadyGoneAtStartDismissesImmediately() async {
        let target = FakeTarget()
        target.exists = false
        var dismissals = 0
        let lifetime = CloseSheetLifetime(
            isTargetAlive: { target.exists },
            dismiss: { dismissals += 1; return true }
        )
        lifetime.start()
        await settle()
        #expect(dismissals == 1)
        lifetime.finish()
    }

    /// A dismissal that cannot land yet must be retried, not abandoned.
    /// This is the queued-sheet case: AppKit will not end a sheet that
    /// has not attached, and nothing about the dead target will change
    /// again to re-trigger the watch, so giving up here strands the
    /// prompt permanently.
    @Test
    func aDismissalThatCannotLandYetIsRetried() async {
        let target = FakeTarget()
        var attempts = 0
        let canDismiss = Cell(false)
        let lifetime = CloseSheetLifetime(
            isTargetAlive: { target.exists },
            dismiss: {
                attempts += 1
                return canDismiss.value
            }
        )
        lifetime.start()
        await settle()

        target.exists = false
        let retried = await waitUntil { attempts > 1 }
        #expect(retried, "the watch gave up after one refused attempt")
        let whileQueued = attempts

        // The sheet ahead of it is answered and this one attaches.
        canDismiss.value = true
        #expect(await waitUntil { attempts > whileQueued })
        lifetime.finish()
    }

    /// A target that comes back while the dismissal is still queued
    /// stands the retry down. A re-admitted pane means the prompt is
    /// answerable again, so taking it down would be wrong.
    @Test
    func aTargetThatReturnsWhileQueuedStopsTheRetry() async {
        let target = FakeTarget()
        var attempts = 0
        let lifetime = CloseSheetLifetime(
            isTargetAlive: { target.exists },
            dismiss: { attempts += 1; return false }
        )
        lifetime.start()
        await settle()
        target.exists = false
        #expect(await waitUntil { attempts > 0 })

        target.exists = true
        await settle()
        let afterReturn = attempts
        await settle()

        #expect(attempts == afterReturn, "the retry kept running for a live target")
        lifetime.finish()
    }

    /// Repeated churn after the target goes must not dismiss twice. The
    /// dismissal ends a sheet, and ending an already-ended one would
    /// reach whatever the window put up next.
    @Test
    func furtherChangesAfterDismissalDoNothing() async {
        let target = FakeTarget()
        var dismissals = 0
        let lifetime = CloseSheetLifetime(
            isTargetAlive: { target.exists },
            dismiss: { dismissals += 1; return true }
        )
        lifetime.start()
        await settle()
        target.exists = false
        await settle()
        target.exists = true
        await settle()
        target.exists = false
        await settle()
        #expect(dismissals == 1)
        lifetime.finish()
    }

    /// An answered prompt calls `finish()`, and the watch must go quiet
    /// even though the target it was watching is about to disappear as a
    /// direct result of that answer. Without this every accepted close
    /// would fire a dismissal into a window that has moved on.
    @Test
    func aFinishedWatchNeverDismisses() async {
        let target = FakeTarget()
        var dismissals = 0
        let lifetime = CloseSheetLifetime(
            isTargetAlive: { target.exists },
            dismiss: { dismissals += 1; return true }
        )
        lifetime.start()
        await settle()
        lifetime.finish()

        target.exists = false
        await settle()

        #expect(dismissals == 0)
    }

    /// `finish()` before `start()` is the race a fast click creates: the
    /// sheet is answered before the deferred arm runs.
    @Test
    func startingAfterFinishNeverDismisses() async {
        let target = FakeTarget()
        target.exists = false
        var dismissals = 0
        let lifetime = CloseSheetLifetime(
            isTargetAlive: { target.exists },
            dismiss: { dismissals += 1; return true }
        )
        lifetime.finish()
        lifetime.start()
        await settle()
        #expect(dismissals == 0)
    }

    /// `finish()` while a refused dismissal is still retrying ends it.
    /// This is what happens when the user answers a queued prompt before
    /// its dead target ever gets it dismissed.
    @Test
    func finishStopsAnInFlightRetry() async {
        let target = FakeTarget()
        target.exists = false
        var attempts = 0
        let lifetime = CloseSheetLifetime(
            isTargetAlive: { target.exists },
            dismiss: { attempts += 1; return false }
        )
        lifetime.start()
        #expect(await waitUntil { attempts > 0 })

        lifetime.finish()
        let afterFinish = attempts
        await settle()

        #expect(attempts == afterFinish, "the retry outlived finish()")
    }
}

/// `.serialized` because each test drives a real `NSWindow` and turns
/// the run loop to let sheet animation settle. Run in parallel, those
/// interleave inside AppKit and take the process down with them.
@MainActor
@Suite(.serialized)
struct CloseSheetDismissalTests {
    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
    }

    /// One short turn of the run loop, which is what sheet presentation
    /// and dismissal need to reach `attachedSheet`. Not async:
    /// `RunLoop.run(until:)` is unavailable from an asynchronous
    /// context, so it has to be reached through a synchronous call like
    /// this one.
    ///
    /// Turning the run loop pumps the main queue, which re-enters every
    /// other `@MainActor` test sharing this process. Keep the slice
    /// short and the total bounded, or suites that pace themselves on
    /// short sleeps start failing next to this one.
    private func turnRunLoop() {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
    }

    /// Drive both schedulers until `condition` holds: the run loop for
    /// AppKit's sheet animation, main-actor turns for the prompt's task
    /// and the watch's re-arm. Returns as soon as it holds, so a test
    /// that is already settled costs one pass, and returns `false`
    /// rather than blocking when it never holds.
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            turnRunLoop()
            await Task.yield()
        }
        return condition()
    }

    /// Give a change that should have no effect enough time to have had
    /// one. Only for the negative assertions, which have no condition to
    /// wait on.
    private func settle() async {
        for _ in 0..<20 {
            turnRunLoop()
            await Task.yield()
        }
    }

    /// Best-effort cleanup: ends attached sheets within fixed bounds and
    /// turns the run loop so their prompts can resume, leaving as little
    /// as possible for the next test in the suite.
    ///
    /// Synchronous, and so callable from `defer`, which is the point: a
    /// `try #require` that throws must not skip this. Ending the sheet
    /// is what resumes the prompt's continuation; turning the run loop
    /// then lets that resumption run. On a passing test there is
    /// nothing attached and this returns immediately.
    private func tearDown(_ windows: NSWindow...) {
        for window in windows {
            // Bounded by the number of sheets any test here stacks on
            // one window, plus slack.
            for _ in 0..<8 {
                guard let sheet = window.attachedSheet else { break }
                // Once per sheet. Dismissal animates, so `attachedSheet`
                // stays this same sheet for a while afterwards, and
                // ending it again on each turn would be a second
                // termination of a sheet already on its way out.
                window.endSheet(sheet, returnCode: .abort)
                var turns = 0
                while window.attachedSheet === sheet, turns < 100 {
                    turnRunLoop()
                    turns += 1
                }
                // It will not come down; leave it rather than spin.
                if window.attachedSheet === sheet { break }
            }
            window.orderOut(nil)
        }
    }

    /// A config with no stored answer, so the prompt actually presents
    /// rather than short-circuiting on a suppression tier.
    private func makeFixture() throws -> Fixture {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("deviceterm-close-sheet-\(UUID().uuidString).conf")
        try "".write(toFile: path, atomically: true, encoding: .utf8)
        return Fixture(
            path: path,
            config: ConfigFile(path: path),
            state: CloseSuppressionState()
        )
    }

    /// Raise the sim-disposition tab prompt, answering into `answer`.
    @discardableResult
    private func askTabClose(
        _ fixture: Fixture,
        window: NSWindow,
        windowID: Int,
        target: FakeTarget,
        into answer: Answer<TabCloseDecision>
    ) -> Task<Void, Never> {
        Task { @MainActor in
            answer.value = await CloseDecisions.tabClose(
                config: fixture.config,
                state: fixture.state,
                context: CloseContext(
                    windowID: WindowID(value: windowID),
                    hasOtherTabsInWindow: true
                ),
                window: window,
                whileTargetLives: { target.exists }
            )
        }
    }

    /// The headline claim: a sheet whose tab is closed underneath it
    /// comes down on its own, the waiting caller is told `.cancel`, and
    /// the window is left with nothing attached.
    @Test
    func removingTheTargetTakesTheSheetDownAndAnswersCancel() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.path) }
        let window = makeWindow()
        defer { tearDown(window) }
        let target = FakeTarget()
        let answer = Answer<TabCloseDecision>()
        askTabClose(fixture, window: window, windowID: 1, target: target, into: answer)

        #expect(await waitUntil { window.attachedSheet != nil }, "the prompt never presented")

        target.exists = false
        let dismissed = await waitUntil { window.attachedSheet == nil }
        #expect(dismissed, "the sheet was left on screen")
        #expect(await waitUntil { answer.value != nil }, "the prompt never returned")
        #expect(answer.value == .cancel)
    }

    /// A second prompt on the same window is queued by AppKit behind the
    /// first, so its dismissal cannot land yet. It must neither be
    /// dismissed early nor forgotten.
    @Test
    func aQueuedSheetIsNotDismissedWhileAnotherIsUp() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.path) }
        let window = makeWindow()
        defer { tearDown(window) }
        let firstTarget = FakeTarget()
        let queuedTarget = FakeTarget()
        let first = Answer<TabCloseDecision>()
        let queued = Answer<TabCloseDecision>()

        askTabClose(fixture, window: window, windowID: 1, target: firstTarget, into: first)
        #expect(await waitUntil { window.attachedSheet != nil })
        let attached = try #require(window.attachedSheet)
        askTabClose(fixture, window: window, windowID: 1, target: queuedTarget, into: queued)
        await settle()

        // The queued prompt's target goes while it is still behind the
        // first one.
        queuedTarget.exists = false
        await settle()

        #expect(window.attachedSheet === attached, "the queued sheet displaced the live one")
        #expect(first.value == nil, "the live prompt was answered for it")
        #expect(queued.value == nil, "the queued prompt answered before presenting")
    }

    @Test
    func aQueuedSheetIsDismissedOnceItsTurnComes() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.path) }
        let window = makeWindow()
        defer { tearDown(window) }
        let firstTarget = FakeTarget()
        let queuedTarget = FakeTarget()
        let first = Answer<TabCloseDecision>()
        let queued = Answer<TabCloseDecision>()

        askTabClose(fixture, window: window, windowID: 1, target: firstTarget, into: first)
        #expect(await waitUntil { window.attachedSheet != nil })
        askTabClose(fixture, window: window, windowID: 1, target: queuedTarget, into: queued)
        await settle()
        queuedTarget.exists = false
        await settle()

        // Answer the sheet in front, which lets the queued one attach.
        window.endSheet(try #require(window.attachedSheet), returnCode: .alertFirstButtonReturn)

        #expect(
            await waitUntil { queued.value != nil },
            "the queued sheet was stranded with no watcher"
        )
        #expect(queued.value == .cancel)
        #expect(first.value == .detach)
        #expect(await waitUntil { window.attachedSheet == nil })
    }

    /// An auto-dismissal must record nothing. The suppression checkbox
    /// is unchecked in this path anyway, but the guarantee callers rely
    /// on is that a prompt nobody answered leaves no preference behind,
    /// so pin every tier rather than the checkbox's default.
    @Test
    func anAutoDismissedPromptRecordsNoSuppression() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.path) }
        let window = makeWindow()
        defer { tearDown(window) }
        let target = FakeTarget()
        let answer = Answer<TabCloseDecision>()
        askTabClose(fixture, window: window, windowID: 2, target: target, into: answer)

        #expect(await waitUntil { window.attachedSheet != nil })
        target.exists = false
        #expect(await waitUntil { answer.value != nil }, "the prompt never returned")

        #expect(fixture.state.perWindow.isEmpty)
        #expect(fixture.state.perSession == nil)
        #expect(ConfigFile(path: fixture.path).value(forKey: CloseDecisions.tabCloseKey) == nil)
        #expect(
            ConfigFile(path: fixture.path).value(forKey: CloseDecisions.tabClosePanesKey) == nil
        )
    }

    /// The multi-pane arm shares `runAlert` but reads its answer
    /// differently (`.alertFirstButtonReturn` means proceed), so an
    /// auto-dismissal has to land as "don't close" there too.
    @Test
    func anAutoDismissedMultiPaneConfirmDoesNotProceed() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.path) }
        let window = makeWindow()
        defer { tearDown(window) }
        let target = FakeTarget()
        let answer = Answer<Bool>()

        Task { @MainActor in
            answer.value = await CloseDecisions.multiPaneTabClose(
                config: fixture.config,
                state: fixture.state,
                context: CloseContext(windowID: WindowID(value: 3), hasOtherTabsInWindow: true),
                paneCount: 2,
                window: window,
                whileTargetLives: { target.exists }
            )
        }

        #expect(await waitUntil { window.attachedSheet != nil })
        target.exists = false
        #expect(await waitUntil { window.attachedSheet == nil }, "the sheet was left on screen")
        #expect(await waitUntil { answer.value != nil }, "the prompt never returned")
        #expect(answer.value == false)
    }

    /// One window's watch must not reach another window's sheet. Both
    /// prompts are up; only the one whose target went away comes down.
    @Test
    func anotherWindowsSheetIsUnaffected() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.path) }
        let doomed = makeWindow()
        let bystander = makeWindow()
        defer { tearDown(doomed, bystander) }
        let doomedTarget = FakeTarget()
        let bystanderTarget = FakeTarget()
        let doomedAnswer = Answer<TabCloseDecision>()
        let bystanderAnswer = Answer<TabCloseDecision>()

        askTabClose(fixture, window: doomed, windowID: 4, target: doomedTarget, into: doomedAnswer)
        askTabClose(
            fixture,
            window: bystander,
            windowID: 5,
            target: bystanderTarget,
            into: bystanderAnswer
        )
        #expect(await waitUntil { doomed.attachedSheet != nil && bystander.attachedSheet != nil })

        doomedTarget.exists = false
        #expect(await waitUntil { doomed.attachedSheet == nil }, "the target's sheet stayed up")
        await settle()

        #expect(await waitUntil { doomedAnswer.value != nil })
        #expect(doomedAnswer.value == .cancel)
        #expect(bystander.attachedSheet != nil, "an unrelated sheet was dismissed")
        #expect(bystanderAnswer.value == nil, "an unrelated prompt was answered")
    }

    /// An answered prompt is the ordinary case, and answering one is
    /// exactly what makes its target disappear. The watch has to be off
    /// by then: a second dismissal would reach into a window that has
    /// moved on, and a second resume of a checked continuation traps, so
    /// this test failing looks like a crash rather than an expectation.
    @Test
    func removingTheTargetAfterAnsweringIsInert() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.path) }
        let window = makeWindow()
        defer { tearDown(window) }
        let target = FakeTarget()
        let answer = Answer<TabCloseDecision>()
        askTabClose(fixture, window: window, windowID: 7, target: target, into: answer)

        #expect(await waitUntil { window.attachedSheet != nil })
        // Detach is the first button, so this is the same answer a click
        // on it produces.
        window.endSheet(try #require(window.attachedSheet), returnCode: .alertFirstButtonReturn)
        #expect(await waitUntil { answer.value != nil })
        #expect(answer.value == .detach)

        target.exists = false
        await settle()

        #expect(window.attachedSheet == nil)
    }

    /// A caller that passes no predicate leaves the sheet up until it is
    /// answered.
    @Test
    func aPromptWithNoWatchStaysUp() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.path) }
        let window = makeWindow()
        defer { tearDown(window) }
        let answer = Answer<TabCloseDecision>()

        Task { @MainActor in
            answer.value = await CloseDecisions.tabClose(
                config: fixture.config,
                state: fixture.state,
                context: CloseContext(windowID: WindowID(value: 6), hasOtherTabsInWindow: true),
                window: window
            )
        }

        #expect(await waitUntil { window.attachedSheet != nil })
        await settle()
        #expect(window.attachedSheet != nil, "the sheet came down with nothing to take it down")
    }
}
