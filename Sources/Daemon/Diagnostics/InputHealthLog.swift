// SPDX-License-Identifier: GPL-3.0-or-later

/// The `input` category's lines, formatted in one place.
///
/// Each line names the pane by short id, the same id `pane show` prints and
/// the "pane published" line carries, so a reader can tie a stall to the HID
/// client the pane was built on.
enum InputHealthLog {
    /// Log the edges of a stall in a pane's input transport.
    ///
    /// Stall transitions are logged separately from individual request errors
    /// so repeated timeouts can be diagnosed as one episode.
    static func stall(_ transition: InputStallTracker.Transition, shortId: String) {
        switch transition {
        case let .began(operation):
            DiagnosticLog.input.notice(
                """
                input stall began: shortId=\(shortId, privacy: .public) \
                op=\(operation, privacy: .public)
                """
            )

        case let .ended(operation, duration, timeouts):
            DiagnosticLog.input.notice(
                """
                input stall ended: shortId=\(shortId, privacy: .public) \
                op=\(operation, privacy: .public) \
                durationMs=\(milliseconds(duration), privacy: .public) \
                timeouts=\(timeouts, privacy: .public)
                """
            )
        }
    }

    /// Log a contact lane shutting and reopening. A shut lane refuses every
    /// new contact on the pane, and the GUI drops that refusal silently, so
    /// this line is the only trace of it.
    static func lane(_ event: ContactLane.HealthEvent, shortId: String) {
        switch event {
        case .shut:
            DiagnosticLog.input.notice(
                "contact lane shut: shortId=\(shortId, privacy: .public)"
            )

        case let .reopened(attempts, duration):
            DiagnosticLog.input.notice(
                """
                contact lane reopened: shortId=\(shortId, privacy: .public) \
                attempts=\(attempts, privacy: .public) \
                durationMs=\(milliseconds(duration), privacy: .public)
                """
            )

        case let .abandoned(attempts, duration):
            DiagnosticLog.input.notice(
                """
                contact lane handed off: shortId=\(shortId, privacy: .public) \
                attempts=\(attempts, privacy: .public) \
                durationMs=\(milliseconds(duration), privacy: .public)
                """
            )
        }
    }

    /// Log a detach that could not free a held contact on its first try, and
    /// again once it stops trying. Nothing is logged for a release that lands
    /// first time.
    static func detachRelease(shortId: String, failedAttempts: Int, finished: Bool, cancelled: Bool) {
        if finished {
            DiagnosticLog.input.notice(
                """
                detach held-contact release finished: shortId=\(shortId, privacy: .public) \
                failedAttempts=\(failedAttempts, privacy: .public) \
                cancelled=\(cancelled, privacy: .public)
                """
            )
        } else {
            DiagnosticLog.input.notice(
                "detach retrying held-contact release: shortId=\(shortId, privacy: .public)"
            )
        }
    }

    static func milliseconds(_ duration: Duration) -> Int64 {
        let parts = duration.components
        return parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000
    }
}
