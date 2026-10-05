// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Testing

/// Covers every hit-test branch. Override-claimed regions must stay with
/// SwiftUI even when its hit test returns nil.
struct PaneChromeHitDecisionTests {
    typealias Decision = PaneChromeHitDecision

    @Test("a real subview is forwarded whatever the override says", arguments: [true, false])
    func subviewIsForwarded(overrideClaims: Bool) {
        #expect(Decision.resolve(swiftUI: .subview, overrideClaims: overrideClaims) == .forward)
    }

    @Test("a real subview never consults the override")
    func subviewSkipsTheOverride() {
        var consulted = false
        _ = Decision.resolve(swiftUI: .subview, overrideClaims: {
            consulted = true
            return true
        }())
        #expect(!consulted)
    }

    @Test("the host answer goes to SwiftUI only where the override claims it", arguments: [
        (true, Decision.Outcome.claim),
        (false, Decision.Outcome.passThrough)
    ])
    func hostAnswer(overrideClaims: Bool, expected: Decision.Outcome) {
        #expect(Decision.resolve(swiftUI: .host, overrideClaims: overrideClaims) == expected)
    }

    @Test("no answer still consults the override", arguments: [
        (true, Decision.Outcome.claim),
        (false, Decision.Outcome.decline)
    ])
    func noAnswer(overrideClaims: Bool, expected: Decision.Outcome) {
        #expect(Decision.resolve(swiftUI: .none, overrideClaims: overrideClaims) == expected)
    }

    /// A claimed region stays with SwiftUI whether its hit test returns the
    /// host or nil.
    @Test("a claimed region is claimed the same way on both answers")
    func claimIsIndependentOfWithholding() {
        let host = Decision.resolve(swiftUI: .host, overrideClaims: true)
        let none = Decision.resolve(swiftUI: .none, overrideClaims: true)
        #expect(host == .claim)
        #expect(none == .claim)
    }
}
