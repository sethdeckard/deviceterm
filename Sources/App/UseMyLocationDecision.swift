// SPDX-License-Identifier: GPL-3.0-or-later
//
// UseMyLocationDecision: what to tell the user when Device ▸ Location ▸
// Use My Location cannot produce a position.
//
// Pure, so every outcome's wording is unit-tested and the mapping is
// total: any `MacLocationFix` that is not a fix produces an alert, which
// is what keeps the menu item from ever failing silently. The view
// controller does the presenting; nothing here touches AppKit.
//
// Naming follows the `CloseDecisions` / `OrphanDecision` convention for
// a pure decision namespace beside a view model.

import Foundation

enum UseMyLocationDecision {
    /// Title of the button that opens `locationServicesURL`.
    static let settingsButtonTitle = "Open Privacy & Security"

    /// Deep link to System Settings ▸ Privacy & Security ▸ Location
    /// Services. The bundle identifier and the `Privacy_LocationServices`
    /// anchor target the macOS 26 Settings extension.
    /// Falling back to a file URL rather than force-unwrapping keeps a
    /// malformed literal from being a termination point, matching
    /// `DaemonStatusSheet.loginItemsURL`.
    static let locationServicesURL: URL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
            + "?Privacy_LocationServices"
    ) ?? URL(fileURLWithPath: "/")

    /// The alert for a position that was taken but could not be applied.
    ///
    /// Separate from the `MacLocationFix` failures because it is a
    /// different story: the Mac answered and the device did not. The
    /// wording stops at "setting it failed" rather than claiming the
    /// device's position is unchanged, since a transport failure can
    /// land after the backend already applied it.
    static func applyFailure(reason: String) -> LocationAlert {
        LocationAlert(
            title: "Couldn't set your location on this device",
            body: "DeviceTerm read this Mac's position, but setting it on the "
                + "device failed. \(reason)",
            settingsURL: nil
        )
    }

    /// The alert for a fix that did not arrive, or nil when one did.
    ///
    /// Total over the failures on purpose: a new `MacLocationFix` case
    /// stops compiling here rather than quietly reaching the user as
    /// nothing happening.
    static func alert(for fix: MacLocationFix) -> LocationAlert? {
        switch fix {
        case .fix:
            return nil

        case .notDetermined:
            return LocationAlert(
                title: "DeviceTerm needs permission to use your location",
                body: "macOS has not been told whether DeviceTerm may read this Mac's "
                    + "location. Allow it under Privacy & Security ▸ Location Services, "
                    + "then choose Use My Location again.",
                settingsURL: locationServicesURL
            )

        case .denied:
            return LocationAlert(
                title: "DeviceTerm cannot use your location",
                body: "Location access for DeviceTerm is turned off. Turn it on under "
                    + "Privacy & Security ▸ Location Services, then choose Use My "
                    + "Location again.",
                settingsURL: locationServicesURL
            )

        case .restricted:
            return LocationAlert(
                title: "Location access is restricted on this Mac",
                body: "A configuration profile or Screen Time setting is blocking "
                    + "location access, so DeviceTerm cannot read this Mac's position. "
                    + "You can still set a position with Custom Coordinates.",
                settingsURL: nil
            )

        case let .unavailable(reason):
            return LocationAlert(
                title: "Couldn't get your location",
                body: reason,
                settingsURL: nil
            )
        }
    }
}
