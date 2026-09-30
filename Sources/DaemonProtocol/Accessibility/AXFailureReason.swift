// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Finite wire vocabulary for `details.reason` on a `-32020` bridge failure
/// from an accessibility verb (`ax tree`, `ax point`, `ax sweep`).
///
/// The error uses the bridge-failure code for clients that ignore `details`;
/// `details.reason` identifies retryable failures. `wait ax` keeps polling
/// through one, and every other bridge failure ends the wait.
public enum AXFailureReason: String, Codable, Sendable, Equatable, CaseIterable {
    /// The accessibility bridge found no frontmost application to read. This
    /// can occur during simulator startup, so a later request may succeed.
    case notReady = "ax.notReady"

    /// The `details` key the reason is written under.
    public static let detailsKey = "reason"
}
