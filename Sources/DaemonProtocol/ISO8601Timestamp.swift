// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The one spelling of a timestamp on deviceterm's wire.
///
/// Internet date-time with fractional seconds, matching what `DaemonEvent`
/// already stamps its events with, so a consumer parsing one field is not
/// surprised by another.
public enum ISO8601Timestamp {
    public static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
