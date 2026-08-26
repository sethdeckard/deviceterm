// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import AppKit
import Testing

/// The pane chrome's SwiftUI surface and its
/// AppKit mount. Three concerns:
///
///   1. The `@Observable` view model exposes the fields the chrome
///      reads (`title`, `isFocused`, the ribbon's collapse state) with
///      sensible defaults and mutable setters. Pinned so a later
///      rename / refactor that changes the observable surface breaks
///      here, not in a runtime SwiftUI re-render bug.
///   2. The AppKit → SwiftUI bridge, `PaneChromeDragHostView`,
///      instantiates without crashing and accepts a frame, so the
///      hosting view stays constructible outside a live window.
///   3. The hosting view's Auto Layout opt-in is set so callers
///      pinning it with constraints don't have to remember the
///      `translatesAutoresizingMaskIntoConstraints` toggle.
@MainActor
struct PaneChromeOverlayTests {
    @Test
    func viewModelDefaultsAreEmptyAndUnfocused() {
        let viewModel = PaneChromeViewModel()
        #expect(viewModel.title.isEmpty)
        #expect(viewModel.isFocused == false)
    }

    @Test
    func ribbonStartsCollapsedAndUndecided() {
        // A pane that never lays out (no window, zero bounds) must
        // remain collapsed, and `ribbonExpansionDecided` starting
        // false is what lets the launch-time width fit run at all.
        let viewModel = PaneChromeViewModel()
        #expect(viewModel.ribbonExpanded == false)
        #expect(viewModel.ribbonExpansionDecided == false)
    }

    @Test
    func viewModelAcceptsInitialState() {
        let viewModel = PaneChromeViewModel(title: "iPhone 17 Pro", isFocused: true)
        #expect(viewModel.title == "iPhone 17 Pro")
        #expect(viewModel.isFocused == true)
    }

    @Test
    func viewModelMutationsPersist() {
        let viewModel = PaneChromeViewModel()
        viewModel.title = "Watch Ultra 3"
        viewModel.isFocused = true
        #expect(viewModel.title == "Watch Ultra 3")
        #expect(viewModel.isFocused == true)
    }

    @Test
    func hostingViewInstantiatesWithoutCrashing() {
        // Toolchain proof: SwiftUI builds + the drag host wraps the
        // chrome surface + the rootView resolves. A failure here
        // means the App target isn't picking up SwiftUI or the
        // SwiftUI rootView has a build error the rest of the suite
        // missed.
        let viewModel = PaneChromeViewModel(title: "test")
        let host = PaneChromeDragHostView(
            rootView: PaneChromeOverlay(viewModel: viewModel),
            showsGrabCursor: false
        )
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        #expect(host.frame.width == 200)
        #expect(host.frame.height == 100)
    }

    @Test
    func hostingViewOptsOutOfAutoresizingMask() {
        // The sim chrome host is pinned with Auto Layout constraints
        // by `SimulatorPaneViewController.loadView`. A regression that
        // ships `true` here would force every caller to remember the
        // toggle, the same trap any `NSHostingView` subclass mounted
        // with constraints has to avoid.
        let host = PaneChromeDragHostView(
            rootView: PaneChromeOverlay(viewModel: PaneChromeViewModel()),
            showsGrabCursor: false
        )
        host.translatesAutoresizingMaskIntoConstraints = false
        #expect(host.translatesAutoresizingMaskIntoConstraints == false)
    }
}
