// SPDX-License-Identifier: GPL-3.0-or-later

/// Coordinated daemon and client bounds for a confirmed rotation.
public enum RotationConfirmationDeadline {
    /// Maximum active or waiting rotation requests the coordinator admits per
    /// pane. This permits one request to wait behind one active predecessor.
    public static let maximumOutstandingPerPane = 2

    /// How long the daemon waits for Simulator display observation after
    /// dispatching the rotation.
    public static let observationMilliseconds = 4_000

    /// Nanosecond form used by the coordinator's suspension.
    public static let observationNanoseconds = UInt64(observationMilliseconds) * 1_000_000

    /// How long a client waits for the complete rotate operation.
    ///
    /// This covers every observation window the enforced per-pane bound allows
    /// ahead of a response, plus ten seconds for backend dispatch and response
    /// delivery.
    public static let clientResponseTimeoutSeconds =
        Double(maximumOutstandingPerPane * observationMilliseconds) / 1_000 + 10

    /// Nanosecond form used by the GUI client's request deadline.
    public static let clientResponseTimeoutNanoseconds =
        UInt64(clientResponseTimeoutSeconds * 1_000_000_000)
}
