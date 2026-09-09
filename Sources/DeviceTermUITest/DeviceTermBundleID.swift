// SPDX-License-Identifier: GPL-3.0-or-later

/// The bundle identifiers the harness targets.
///
/// The app and the daemon are separate processes: DeviceTerm.app owns the
/// tab/pane chrome, while the menu-bar status item (an iPhone glyph plus a
/// count) belongs to the daemon's faceless helper. A window capture of the
/// *app* therefore never contains the status item, which is captured on
/// its own via the status-item path. The harness never captures a whole
/// display.
///
/// The status *item* is the daemon's; its *window* is not. macOS hosts
/// every menu-bar extra in Control Center's process, so neither of these
/// bundle ids identifies that window. `StatusItemLocator` obtains the
/// item's frame through accessibility, and the capture path matches that
/// frame to a window.
enum DeviceTermBundleID {
    /// DeviceTerm.app: windows, tab strip, panes, modal alerts.
    static let app = "com.deviceterm"

    /// The faceless daemon helper that owns the menu-bar status item.
    static let daemon = "com.deviceterm.daemon"
}
