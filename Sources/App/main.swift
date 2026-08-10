// SPDX-License-Identifier: GPL-3.0-or-later
//
// deviceterm GUI entry point. The main menu is built in MainMenu.swift.

import AppKit

let app = NSApplication.shared
// Composition root: construct the one real daemon client and inject it.
// `AppDelegate` owns its connection lifecycle and hands narrow role
// protocols (see `DaemonClienting`) down to the controllers.
let delegate = AppDelegate(daemonClient: DaemonClient())
app.delegate = delegate
app.setActivationPolicy(.regular)
installMainMenu()
app.activate(ignoringOtherApps: true)
app.run()
