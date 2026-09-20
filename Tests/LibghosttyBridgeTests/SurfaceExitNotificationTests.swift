// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import LibghosttyBridge
@testable import TerminalSurface
import Testing

/// The exit latch: one notification per surface, whichever engine signal
/// arrives.
///
/// Two paths reach it. An explicit-command surface does not close itself on
/// child exit, so the action is the only exit signal it gets. Close requests
/// still invoke `close_surface_cb`, and a normal exit invokes it too when
/// `wait-after-command` is false. Whichever arrives first has to be the one
/// and only exit the delegate sees.
///
/// Constructing the surface without attaching is what makes this testable: no
/// runtime, no GPU, no `NSApp`. Everything past `attach()` still belongs to the
/// harness binary.
@MainActor
struct SurfaceExitNotificationTests {
    private final class ExitRecorder: TerminalSurfaceDelegate {
        private(set) var exitCount = 0
        private(set) var codes: [Int32?] = []

        func terminalSurface(_ surface: any TerminalSurface, didChangeTitle title: String) {}

        func terminalSurface(
            _ surface: any TerminalSurface,
            didChangeWorkingDirectory path: String
        ) {}

        func terminalSurface(_ surface: any TerminalSurface, didExitWithCode code: Int32?) {
            exitCount += 1
            codes.append(code)
        }

        func terminalSurfaceWantsBell(_ surface: any TerminalSurface) {}
    }

    private func makeSurface() -> (GhosttyTerminalSurface, ExitRecorder) {
        let surface = GhosttyTerminalSurface(resourcesDirectory: nil, loadUserConfig: false)
        let recorder = ExitRecorder()
        surface.delegate = recorder
        return (surface, recorder)
    }

    @Test
    func theChildExitedActionReportsAnExit() {
        let (surface, recorder) = makeSurface()
        surface.engineDidReportChildExit()
        #expect(recorder.exitCount == 1)
    }

    @Test
    func theCloseCallbackReportsAnExit() {
        let (surface, recorder) = makeSurface()
        surface.engineDidRequestClose(processAlive: false)
        #expect(recorder.exitCount == 1)
    }

    /// The engine can emit the action and then close. The latch is what stops
    /// that becoming two exit notifications for the one surface.
    @Test
    func theActionThenTheCallbackReportsOnce() {
        let (surface, recorder) = makeSurface()
        surface.engineDidReportChildExit()
        surface.engineDidRequestClose(processAlive: false)
        #expect(recorder.exitCount == 1)
    }

    /// The latch does not privilege either signal: whichever lands first is the
    /// exit, and the other is ignored. `requestClose()` reaches the callback
    /// too, so a host-initiated teardown is the case that arrives in this
    /// order.
    @Test
    func theCallbackThenTheActionReportsOnce() {
        let (surface, recorder) = makeSurface()
        surface.engineDidRequestClose(processAlive: true)
        surface.engineDidReportChildExit()
        #expect(recorder.exitCount == 1)
    }

    @Test
    func repeatedActionsReportOnce() {
        let (surface, recorder) = makeSurface()
        surface.engineDidReportChildExit()
        surface.engineDidReportChildExit()
        surface.engineDidReportChildExit()
        #expect(recorder.exitCount == 1)
    }

    /// nil means "unknown", not "clean". libghostty's macOS launch path
    /// reports 0 however the process died, so a code would assert something
    /// the bridge cannot know.
    @Test
    func theReportedCodeIsUnknown() {
        let (surface, recorder) = makeSurface()
        surface.engineDidReportChildExit()
        #expect(recorder.codes == [nil])
    }

    /// The latch is per surface, so one pane's shell exiting says nothing
    /// about another's.
    @Test
    func eachSurfaceLatchesIndependently() {
        let (first, firstRecorder) = makeSurface()
        let (second, secondRecorder) = makeSurface()
        first.engineDidReportChildExit()
        first.engineDidReportChildExit()
        #expect(firstRecorder.exitCount == 1)
        #expect(secondRecorder.exitCount == 0)
        second.engineDidReportChildExit()
        #expect(secondRecorder.exitCount == 1)
    }
}
