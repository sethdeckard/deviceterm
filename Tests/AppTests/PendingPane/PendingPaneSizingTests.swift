// SPDX-License-Identifier: GPL-3.0-or-later
//
// Pending-pane sizing: a pending placeholder must size identically to
// the sim/device pane it becomes (so the success swap doesn't resize),
// and its family must reach the layout controller via
// `PendingPaneViewController.family`. These pin the pure metric helper
// + the VC's exposed family without needing a window-attached split
// view.

@testable import App
import CoreGraphics
import DaemonProtocol
import Testing

@MainActor
struct PendingPaneSizingTests {
    private func naturalExtent(_ family: String, isVerticalDivider: Bool) -> CGFloat {
        PaneLayoutViewController.mirroredMetric(
            slot: .pending(PendingPaneID(value: 1)),
            family: DeviceFamily(wire: family),
            isVerticalDivider: isVerticalDivider
        ).naturalExtent
    }

    @Test
    func pendingMetricUsesFamilyExtents() {
        // Vertical divider → width along the axis; horizontal → height.
        #expect(naturalExtent("phone", isVerticalDivider: true) == 380)
        #expect(naturalExtent("phone", isVerticalDivider: false) == 280)
        #expect(naturalExtent("watch", isVerticalDivider: true) == 220)
        #expect(naturalExtent("watch", isVerticalDivider: false) == 200)
        // Unknown (a physical device, or a sim before family is known) →
        // phone-default.
        #expect(naturalExtent("unknown", isVerticalDivider: true) == 380)
        #expect(naturalExtent("unknown", isVerticalDivider: false) == 280)
        // Non-flexible: a pending pane aspect-fits like a sim, it doesn't
        // absorb leftover space the way a terminal does.
        let metric = PaneLayoutViewController.mirroredMetric(
            slot: .pending(PendingPaneID(value: 1)),
            family: .phone,
            isVerticalDivider: true
        )
        #expect(!metric.isFlexible)
    }

    @Test
    func pendingMetricMatchesSimMetricForSameFamily() {
        // Fitting parity: a pending leaf and a real sim leaf with the
        // same family produce identical extents, so the success swap is
        // a no-resize.
        for family in [DeviceFamily.phone, .watch, .unknown] {
            for vertical in [true, false] {
                let pendingMetric = PaneLayoutViewController.mirroredMetric(
                    slot: .pending(PendingPaneID(value: 1)),
                    family: family,
                    isVerticalDivider: vertical
                )
                let simMetric = PaneLayoutViewController.mirroredMetric(
                    slot: .sim(udid: "U"),
                    family: family,
                    isVerticalDivider: vertical
                )
                #expect(pendingMetric.naturalExtent == simMetric.naturalExtent)
                #expect(pendingMetric.minimumExtent == simMetric.minimumExtent)
            }
        }
    }

    @Test
    func pendingViewControllerExposesFamilyForLayout() {
        let watch = PendingPaneViewController(
            pending: PendingPaneState(
                id: PendingPaneID(value: 1),
                target: .sim(udid: "U"),
                displayName: "Watch",
                family: "watch"
            )
        )
        #expect(watch.family == "watch")
        // No family supplied → `.unknown` (→ phone-default sizing).
        let unknown = PendingPaneViewController(
            pending: PendingPaneState(
                id: PendingPaneID(value: 2),
                target: .device(deviceId: "d"),
                displayName: nil
            )
        )
        #expect(unknown.family == DeviceFamily.unknown.rawValue)
    }
}
