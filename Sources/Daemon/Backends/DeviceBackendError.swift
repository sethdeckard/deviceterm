// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import DaemonProtocol
import Foundation

/// Backend-level error vocabulary. The coordinator translates these to
/// `PaneError`, adding the paneId + verb context it owns. Genuine
/// bridge send-errors are deliberately *not* wrapped here. They
/// propagate raw so the coordinator wraps them as `bridgeFailed` via
/// `BridgeMessage.unwrap`.
enum DeviceBackendError: Error {
    /// The backend has been torn down (its sim shut down / its device
    /// detached). The coordinator maps it to `paneNotActive`.
    case notActive
    /// Lazy accessibility acquisition permanently failed for this
    /// backend (the platform-translation framework is missing on this
    /// host). Carries the message the coordinator surfaces under the
    /// `ax.acquire` operation.
    case accessibilityUnavailable(message: String)
    /// Edge-tagged system gestures (home / App Switcher) aren't supported
    /// by this backend kind. Only the CoreSimulator backend implements
    /// them; physical devices use their own gesture path.
    case unsupportedEdgeGesture
    /// Location simulation isn't implemented by this backend kind (the
    /// stub, and any conformer that takes the protocol defaults).
    case unsupportedLocation
    /// Lazy location acquisition permanently failed for this backend.
    /// Carries the first failure's message so a retry classifies the
    /// same way the original did, as `accessibilityUnavailable` does.
    ///
    /// **Acquisition only.** The wire mapper labels this
    /// `location.acquire`, so a failure that happened while *performing*
    /// a command must not borrow it. The client would be told the
    /// acquisition failed for an operation that got past acquisition
    /// fine. Use `locationCommandFailed` for those.
    case locationUnavailable(message: String)
    /// A location command reached the device layer and failed there, a
    /// non-zero `devicectl` exit being the usual case. Distinct from
    /// `locationUnavailable` so the wire error names the verb the caller
    /// actually invoked rather than a hardcoded acquisition step.
    case locationCommandFailed(message: String)
    /// The location tool answered, but its output couldn't be
    /// understood: a payload whose shape doesn't match what this version
    /// expects.
    ///
    /// Split from `locationUnavailable` because the two demand opposite
    /// responses. A device that isn't reachable is routine, and callers
    /// degrade quietly. Unintelligible output means the tool's schema
    /// moved under us, which is a defect: it makes every device look
    /// like it has no trips, and it is invisible unless something says
    /// so. Keeping it distinguishable is what lets a caller degrade
    /// *and* complain.
    case locationOutputMalformed(message: String)
    /// A scenario absent from a simulator backend's available scenarios.
    /// Rejected before calling CoreSimulator because its setter silently
    /// accepts unknown names, returning success while changing nothing.
    /// The physical-device backend forwards names to `devicectl`, which
    /// reports its own rejection.
    case unknownLocationScenario(name: String)
}
