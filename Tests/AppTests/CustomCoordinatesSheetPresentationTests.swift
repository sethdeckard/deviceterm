// SPDX-License-Identifier: GPL-3.0-or-later
//
// CustomCoordinatesSheetPresentationTests: the AppKit half of Custom
// Coordinates, which the pure `CoordinateInput` tests can't reach.
//
// The claim worth pinning is that the sheet actually closes. AppKit
// overloads `dismiss`: `dismiss(_ sender: Any?)` is `dismissController:`
// and dismisses *the receiver*, so calling it on the presenting
// controller compiles, runs, and leaves the sheet on screen forever.
// Only `dismiss(_ viewController:)` closes a sheet you presented, and
// nothing but a test distinguishes the two.
//
// Submit and cancel call the same dismissal helper. The injected
// locations store keeps the submit path off the user's filesystem, so
// both callbacks can be exercised through the presented sheet.

@testable import App
import AppKit
import DaemonProtocol
import SwiftUI
import Testing

/// `.serialized` because each test drives a real `NSWindow` and turns
/// the run loop to let sheet animation settle. Run in parallel, those
/// interleave inside AppKit and take the process down with them.
@MainActor
@Suite(.serialized)
struct CustomCoordinatesSheetPresentationTests {
    /// `@unchecked Sendable`: every access to `storage` is guarded by
    /// `lock`.
    private final class RecordingLocationsStore: LocationsStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [LocationEntry] = []

        var entries: [LocationEntry] { lock.withLock { storage } }

        func load() -> [LocationEntry] { entries }

        func record(_ entry: LocationEntry) {
            lock.withLock { storage.append(entry) }
        }
    }

    /// The pane plus the window it needs. `presentAsSheet` asserts that
    /// the presenting controller's view has a window, so the window is
    /// part of the fixture rather than an optional extra; the caller
    /// holds it for the duration.
    private func makeViewController(
        client: FakeDaemonClient = FakeDaemonClient(),
        locations: any LocationsStoring = RecordingLocationsStore()
    ) -> (SimulatorPaneViewController, NSWindow) {
        let pane = SimPaneState(
            paneId: "p1",
            udid: "U-TEST",
            displayName: "iPhone 17 Pro",
            family: "phone"
        )
        let controller = SimulatorPaneViewController(
            simPane: pane,
            daemonClient: client,
            locations: locations
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        return (controller, window)
    }

    /// Sheet presentation and dismissal animate, so the run loop has to
    /// turn before `presentedViewControllers` settles.
    private func settle() {
        for _ in 0..<20 {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
    }

    private func sheet(
        of controller: SimulatorPaneViewController
    ) -> NSHostingController<CustomCoordinatesSheet>? {
        controller.presentedViewControllers?
            .compactMap { $0 as? NSHostingController<CustomCoordinatesSheet> }
            .first
    }

    @Test("the menu action presents the sheet")
    func actionPresentsTheSheet() {
        let (controller, window) = makeViewController()
        defer { window.contentViewController = nil; window.orderOut(nil) }
        #expect(sheet(of: controller) == nil)
        controller.showCustomCoordinates(nil)
        settle()
        #expect(sheet(of: controller) != nil)
    }

    /// Cancel has to close it. With `dismiss(nil)` on the presenter this
    /// fails: the sheet stays up and the pane is stuck behind a modal.
    @Test("cancelling closes the sheet")
    func cancelDismissesTheSheet() throws {
        let (controller, window) = makeViewController()
        defer { window.contentViewController = nil; window.orderOut(nil) }
        controller.showCustomCoordinates(nil)
        settle()
        let presented = try #require(sheet(of: controller))

        presented.rootView.onCancel()
        settle()
        #expect(sheet(of: controller) == nil, "the sheet was left on screen")
    }

    @Test("submitting closes the sheet, saves the point, and applies it")
    func submitDismissesAndAppliesTheLocation() async throws {
        let client = FakeDaemonClient()
        let locations = RecordingLocationsStore()
        let (controller, window) = makeViewController(client: client, locations: locations)
        defer { window.contentViewController = nil; window.orderOut(nil) }
        controller.showCustomCoordinates(nil)
        settle()
        let presented = try #require(sheet(of: controller))
        let location = SimulatedLocation.coordinate(latitude: 37.7749, longitude: -122.4194)

        presented.rootView.onSubmit(location, "Office")
        settle()
        for _ in 0..<20 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        #expect(sheet(of: controller) == nil, "the sheet was left on screen")
        #expect(locations.entries == [
            .coordinate(latitude: 37.7749, longitude: -122.4194, label: "Office")
        ])
        #expect(client.locationSetCalls == [.init(paneId: "p1", location: location)])
    }

    @Test(
        "custom-coordinate names are normalized",
        arguments: [
            ("  Office  ", "Office"),
            ("\tOffice\t", "Office"),
            ("   ", nil),
            ("", nil)
        ] as [(String, String?)]
    )
    func nameNormalization(input: String, expected: String?) {
        #expect(CustomCoordinatesSheet.normalizedName(input) == expected)
    }
}
