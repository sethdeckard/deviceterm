// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Testing

/// Reference sink so the render closure mutates shared state cleanly
/// under strict concurrency (everything stays main-actor isolated).
@MainActor
private final class RenderSink {
    var titles: [String] = []
}

/// The `observe()` keystone. Validates the Observation→render bridge
/// headlessly (no AppKit): an immediate first render, a re-render on the
/// next main-actor turn when a *read* property changes, no render after
/// cancel(), and the tracking contract (a short-circuited field isn't
/// observed). TabTitleViewModel stands in as the @Observable source.
@MainActor
struct ObserveTests {
    /// Let the re-arm `Task { @MainActor … }` scheduled by onChange run.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 20_000_000)  // 20ms
    }

    @Test
    func rendersImmediatelyThenOnTrackedChange() async {
        let model = TabTitleViewModel()
        let sink = RenderSink()
        let token = observe { sink.titles.append(model.displayTitle) }
        #expect(sink.titles == ["shell"])               // immediate first render

        model.updateWorkingDirectory(path: "/tmp/foo")
        await settle()
        #expect(sink.titles == ["shell", "foo"])        // tracked change → re-render

        token.cancel()
        model.updateWorkingDirectory(path: "/tmp/bar")
        await settle()
        #expect(sink.titles == ["shell", "foo"])        // cancelled → no further render
    }

    @Test
    func doesNotTrackShortCircuitedField() async {
        let model = TabTitleViewModel()
        model.updateOSCTitle("osc")                     // OSC set → displayTitle
        let sink = RenderSink()                          // short-circuits before CWD
        let token = observe { sink.titles.append(model.displayTitle) }
        #expect(sink.titles == ["osc"])

        model.updateWorkingDirectory(path: "/tmp/foo")  // CWD wasn't read this pass
        await settle()
        #expect(sink.titles == ["osc"])                 // so no re-render
        token.cancel()
    }
}
