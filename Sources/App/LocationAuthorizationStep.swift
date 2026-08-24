// SPDX-License-Identifier: GPL-3.0-or-later

/// What the provider should do next.
enum LocationAuthorizationStep: Equatable, Sendable {
    /// Ask macOS to show the permission prompt.
    case requestAuthorization
    /// Permission is in hand; ask for a position.
    case requestLocation
    /// Nothing has been decided. Stay pending.
    case keepWaiting
    /// Resolve the request with this outcome.
    case finish(MacLocationFix)
}
