// SPDX-License-Identifier: GPL-3.0-or-later
/// A snapshot of what a `MirrorPipeline`'s receive loop has done so far.
///
/// Every field is a monotonic counter over the pipeline's whole lifetime, not a
/// gauge, so a caller reads two snapshots and compares them rather than reading
/// one and interpreting it. It lets the live-device tests observe decoded
/// frames, Receiver Report attempts, and restart scheduling against hardware;
/// nothing in the product reads it, and no counter here influences the
/// pipeline's own behavior.
package struct MirrorObservation: Sendable, Equatable {
    /// Decode callbacks accepted while the feed was running, summed across
    /// sessions. The pipeline's per-session tally resets on each restart; this
    /// one does not. Delivery to the consumer happens afterwards and keeps only
    /// the newest frame, so this is not a count of frames a consumer saw.
    package let framesDelivered: Int

    /// Receiver Reports handed to the socket. `DatagramIngress.send` returns
    /// `Void` and drops a failed address parse or `sendto`, so this counts
    /// attempts; it is not evidence that any report left the host, let alone
    /// reached the device.
    package let receiverReportAttempts: Int

    /// Times a session ended and the receive loop scheduled a restart, whether
    /// the watchdog forced it or the session ended on its own. The next session
    /// still has to survive the backoff, so a stop can land in between.
    package let sessionRestarts: Int

    package init(framesDelivered: Int, receiverReportAttempts: Int, sessionRestarts: Int) {
        self.framesDelivered = framesDelivered
        self.receiverReportAttempts = receiverReportAttempts
        self.sessionRestarts = sessionRestarts
    }
}
