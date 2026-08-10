// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Testing

@testable import App

struct PaneRatioMathTests {
    // MARK: - evenSplit

    @Test
    func evenSplitDividesEqually() {
        #expect(PaneRatioMath.evenSplit(count: 4) == [0.25, 0.25, 0.25, 0.25])
        #expect(PaneRatioMath.evenSplit(count: 1) == [1.0])
    }

    @Test
    func evenSplitNonPositiveCountIsEmpty() {
        #expect(PaneRatioMath.evenSplit(count: 0).isEmpty)
        #expect(PaneRatioMath.evenSplit(count: -3).isEmpty)
    }

    // MARK: - normalize

    @Test
    func normalizeProducesProportionsSummingToOne() throws {
        let result = try #require(PaneRatioMath.normalize([100, 300]))
        #expect(result == [0.25, 0.75])
        #expect(abs(result.reduce(0, +) - 1) < 1e-9)
    }

    @Test
    func normalizeNonPositiveTotalIsNil() {
        #expect(PaneRatioMath.normalize([]) == nil)
        #expect(PaneRatioMath.normalize([0, 0]) == nil)
        #expect(PaneRatioMath.normalize([-5]) == nil)
    }

    // MARK: - proportions

    @Test
    func proportionsNormalizesNaturalExtents() {
        #expect(PaneRatioMath.proportions(naturalExtents: [200, 200]) == [0.5, 0.5])
    }

    @Test
    func proportionsFallsBackToEvenSplitWhenDegenerate() {
        // Zero total → even split across the same count.
        #expect(PaneRatioMath.proportions(naturalExtents: [0, 0, 0]).allSatisfy {
            abs($0 - 1.0 / 3.0) < 1e-9
        })
    }

    // MARK: - usableExtent

    @Test
    func usableExtentReservesDividerThickness() {
        // Three panes → two dividers of thickness 10 → 200 - 20 = 180.
        #expect(PaneRatioMath.usableExtent(axisExtent: 200, dividerThickness: 10, count: 3) == 180)
        // One pane → no dividers reserved.
        #expect(PaneRatioMath.usableExtent(axisExtent: 200, dividerThickness: 10, count: 1) == 200)
    }

    @Test
    func usableExtentNeverNegative() {
        // Dividers exceed the axis → clamp to 0, not a negative extent.
        #expect(PaneRatioMath.usableExtent(axisExtent: 5, dividerThickness: 10, count: 3) == 0)
    }

    // MARK: - dividerPositions

    @Test
    func dividerPositionsAreCumulativeAcrossThickness() {
        // 50/50 across 180 usable with a 10pt divider: first divider at
        // 90, and there is only one interior divider for two panes.
        #expect(PaneRatioMath.dividerPositions(
            ratios: [0.5, 0.5],
            usableExtent: 180,
            dividerThickness: 10
        ) == [90])
    }

    @Test
    func dividerPositionsForThreePanesStepOverDividers() {
        // 25/25/50 across 180 usable, 10pt dividers:
        //   d0 = 0.25*180 = 45
        //   d1 = 45 + 10 + 0.25*180 = 100
        #expect(PaneRatioMath.dividerPositions(
            ratios: [0.25, 0.25, 0.5],
            usableExtent: 180,
            dividerThickness: 10
        ) == [45, 100])
    }

    @Test
    func dividerPositionsSinglePaneIsEmpty() {
        #expect(PaneRatioMath.dividerPositions(
            ratios: [1.0],
            usableExtent: 100,
            dividerThickness: 10
        ).isEmpty)
    }

    // MARK: - round trip

    @Test
    func ratiosRoundTripThroughPositionsAndBack() throws {
        // Apply ratios → divider positions → the resulting pane extents →
        // normalize back to ratios. With no divider thickness the values
        // should be stable.
        let ratios: [CGFloat] = [0.2, 0.3, 0.5]
        let usable: CGFloat = 300
        let positions = PaneRatioMath.dividerPositions(
            ratios: ratios,
            usableExtent: usable,
            dividerThickness: 0
        )
        // Reconstruct each pane's extent from the divider positions.
        var extents: [CGFloat] = []
        var previous: CGFloat = 0
        for position in positions {
            extents.append(position - previous)
            previous = position
        }
        extents.append(usable - previous)
        let recovered = try #require(PaneRatioMath.normalize(extents))
        for (expected, actual) in zip(ratios, recovered) {
            #expect(abs(expected - actual) < 1e-9)
        }
    }
}
