// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Sparkle

/// Tells Sparkle's ordinary outcomes apart from real faults.
///
/// Sparkle reports "no update available" and both ways a user declines an
/// install through the same failure channels as a genuine error, so without
/// this an updater behaving perfectly would write `.error` records for routine
/// no-update and authorization-decline outcomes. Sparkle excludes the same
/// three codes from its own logging.
enum SparkleErrorOutcome {
    static let benignCodes: Set<Int> = [
        Int(SUError.noUpdateError.rawValue),
        Int(SUError.installationCanceledError.rawValue),
        Int(SUError.installationAuthorizeLaterError.rawValue)
    ]

    static func isBenign(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == SUSparkleErrorDomain
            && benignCodes.contains(error.code)
    }
}
