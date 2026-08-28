// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Foundation
import Sparkle
import Testing

/// Pins which Sparkle failures are ordinary outcomes.
///
/// Sparkle reports "no update available" and a declined install through the
/// same channels as a real fault, so misclassifying one writes `.error`
/// records for a perfectly healthy updater and buries the real faults.
struct SparkleErrorOutcomeTests {
    private func sparkleError(_ code: Int32) -> NSError {
        NSError(domain: SUSparkleErrorDomain, code: Int(code))
    }

    @Test("ordinary outcomes", arguments: [
        SUError.noUpdateError,
        SUError.installationCanceledError,
        SUError.installationAuthorizeLaterError
    ])
    func treatsOrdinaryOutcomesAsBenign(code: SUError) {
        #expect(SparkleErrorOutcome.isBenign(sparkleError(code.rawValue)))
    }

    /// A real fault has to stay loud, and so does a same-numbered code from
    /// somewhere other than Sparkle.
    @Test
    func treatsRealFaultsAsNotBenign() {
        #expect(!SparkleErrorOutcome.isBenign(sparkleError(SUError.downloadError.rawValue)))
        #expect(!SparkleErrorOutcome.isBenign(sparkleError(SUError.appcastParseError.rawValue)))

        let foreign = NSError(
            domain: NSURLErrorDomain,
            code: Int(SUError.noUpdateError.rawValue)
        )
        #expect(!SparkleErrorOutcome.isBenign(foreign))
    }
}
