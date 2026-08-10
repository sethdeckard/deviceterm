// SPDX-License-Identifier: GPL-3.0-or-later
//
// DeviceTermBundleID: the bundle identifiers the harness targets.
//
// The app and the daemon are separate processes with separate windows:
// DeviceTerm.app owns the tab/pane chrome, while the menu-bar status
// item ("📱 N") belongs to the daemon's faceless helper. A window capture
// of the *app* therefore never contains the status item, which is the
// daemon's own (menu-bar-layer) window, captured on its own via the
// status-item path. The harness never captures a whole display.

enum DeviceTermBundleID {
    /// DeviceTerm.app: windows, tab strip, panes, modal alerts.
    static let app = "com.deviceterm"

    /// The faceless daemon helper that owns the menu-bar status item.
    static let daemon = "com.deviceterm.daemon"
}
