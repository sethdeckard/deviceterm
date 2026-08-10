// SPDX-License-Identifier: GPL-3.0-or-later
//
// PaneLocationStateResult: wire shape returned by `pane.location.state`.
//
// A struct rather than a bare `SimulatedLocation` so later fields (a
// route's playback state, say) are additive rather than wire-breaking.

/// What deviceterm last applied to a pane, and what that pane's device
/// offers.
public struct PaneLocationStateResult: Codable, Sendable, Equatable {
    /// **What deviceterm last set, not a reading from the device.** `nil`
    /// when deviceterm has no claim to make.
    ///
    /// Neither backend exposes a getter (CoreSimulator vends only the
    /// setters and `availableLocationScenarios`; `devicectl` has no read
    /// verb), so this is the daemon's own claim about a device it may
    /// not exclusively control. A change made out of band (Simulator.app's
    /// own Features ▸ Location, a raw `simctl location` call, an Xcode
    /// scheme's default location) leaves this value stale, and nothing
    /// can detect that. It is dropped only by the events that make it
    /// indefensible: an ownership-transfer commit, a shutdown or failure
    /// (including the reboot path), or a fresh record. A same-session
    /// re-attach is idempotent and deliberately preserves the claim,
    /// since the owner and its writes are unchanged.
    ///
    /// **`nil` is not `.cleared`.** `.cleared` is a positive statement
    /// that deviceterm cleared the simulation; `nil` says only that
    /// deviceterm doesn't know what, if anything, the device is
    /// simulating.
    ///
    /// Neither route to `nil` justifies reporting `.cleared`, because
    /// none of them sends a clear. An **ownership transfer** leaves the
    /// device untouched, so nothing about its position can be inferred.
    /// A **shutdown, failure, or reboot** very likely dropped the
    /// simulation with the device's state, but deviceterm neither did
    /// that nor can confirm it. A caller renders `nil` by checking
    /// nothing, the only display that is honest in both cases.
    public let location: SimulatedLocation?
    /// The named trips this pane's device offers, in the order the
    /// device reports them. A name is the identifier
    /// `pane.location.set` consumes, so a device reporting one twice is
    /// an anomaly; `LocationMenuModel` tolerates it rather than assuming
    /// the list is well formed.
    ///
    /// Empty means no scenarios are available: the device may be stopped,
    /// or enumeration may have failed. A simulator enumerates scenarios
    /// only while booted, so a stopped device reporting none is expected
    /// rather than an error, and the daemon degrades a failed enumeration
    /// to the same empty list.
    public let scenarios: [String]

    public init(location: SimulatedLocation?, scenarios: [String]) {
        self.location = location
        self.scenarios = scenarios
    }
}
