// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Observation

/// Presentation state for the "Mirror Physical
/// Device…" picker. Loads the connected-device roster from the daemon
/// (`physicalDevice.list`) and, on selection, hands the chosen device's
/// id + display name back to the host (AppDelegate) which dispatches
/// `Route.attachDevicePane` against the current tab and closes the
/// picker. Bypasses PaneResurrect / DiscoveryDecision entirely: discovery
/// models owned-booted *sims*, and the resurrect watch re-attaches a pane
/// that lost its device, while this mounts one the tab isn't showing yet.
/// A physical device is mounted through this picker, `deviceterm device
/// attach`, or the shim's contextual auto-attach.
///
/// The daemon dependency is the narrow `PhysicalDeviceControlling` role
/// so the VM (and its test fake) depend on just the two device RPCs.
@MainActor
@Observable
final class DevicePickerViewModel {
    /// Connected devices from the last load. Empty until `load()`
    /// completes (or when none are connected).
    private(set) var devices: [PhysicalDeviceListEntry] = []
    /// True while `physicalDevice.list` is in flight, during which the view shows a
    /// progress indicator.
    private(set) var isLoading = false
    /// Set when the list RPC throws; surfaced in the view so a failure
    /// reads as an error rather than an empty roster.
    private(set) var loadError: String?

    @ObservationIgnored private let daemon: any PhysicalDeviceControlling
    /// Invoked with the chosen `(deviceId, displayName)` when the user
    /// picks an available device. The host dispatches the attach route
    /// and closes the window. `displayName` is the device's best-effort
    /// name/model, or nil (the Router then composes from the attach
    /// response).
    @ObservationIgnored private let attach: (String, String?) -> Void
    /// Invoked when the user cancels (or after a successful pick) so the
    /// host can tear the window down.
    @ObservationIgnored private let dismiss: () -> Void

    init(
        daemon: any PhysicalDeviceControlling,
        attach: @escaping (String, String?) -> Void,
        dismiss: @escaping () -> Void
    ) {
        self.daemon = daemon
        self.attach = attach
        self.dismiss = dismiss
    }

    /// Fetch the connected-device roster. Idempotent-safe to call again
    /// (e.g. a Refresh button); it resets the error and reloads.
    func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            devices = try await daemon.physicalDeviceList()
        } catch {
            devices = []
            loadError = "\(error)"
        }
    }

    /// Mount `entry` if it's available. Composes the display name from
    /// the device's name then model (nil when neither is known, in which case the
    /// Router falls back to the attach response). Unavailable entries
    /// are ignored (the view disables their row, but guard here too so a
    /// programmatic call can't bypass it).
    func select(_ entry: PhysicalDeviceListEntry) {
        guard entry.available else { return }
        attach(entry.deviceId, entry.name ?? entry.model)
        dismiss()
    }

    func cancel() {
        dismiss()
    }
}
