// SPDX-License-Identifier: GPL-3.0-or-later

/// Umbrella composition of the daemon role protocols.
///
/// For the AppKit *forwarding glue*: the controllers that don't drive
/// the daemon much themselves but hand the client down to a deeper
/// consumer (e.g. `TabStripViewController` → `TabContentViewController` → `SimulatorPaneViewController`).
/// Such a hub needs the union of every role its subtree touches, so a
/// single `any DaemonClienting` reads better than spelling each one out
/// at each property/parameter.
///
/// NOT a fat protocol: it composes the roles, it doesn't replace
/// them. Narrow consumers, view models included, must still depend
/// on the smallest role(s) they use (`SimResurrect` on
/// `DeviceControlling`, a pane VM on `PaneControlling & PaneSubscribing`,
/// the device picker on `PhysicalDeviceControlling`), never on this alias.
/// `DaemonClient` is the sole concrete conformer (it conforms to the roles
/// on its primary type, per AGENTS.md).
typealias DaemonClienting =
    SessionControlling & DeviceControlling & PhysicalDeviceControlling
    & PaneControlling & PaneSubscribing & PaneAccessibilityControlling
    & PaneLocationControlling
    & TerminalBinding & ReconnectObserving & AutomationGranting
    & DisplayTitlePublishing
