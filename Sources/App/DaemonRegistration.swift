// SPDX-License-Identifier: GPL-3.0-or-later
//
// DaemonRegistration: thin wrapper around
// `SMAppService.agent(plistName:)`.
//
// macOS 13+ exposes a Swift API for what was historically
// SMJobBless: register a launchd plist embedded under
// `Contents/Library/LaunchAgents/` and let launchd own the
// helper's lifecycle. The wrapper:
//
//   - Wraps the plist-name constant and the `register()` call so
//     callers see one entry point.
//   - Exposes the current `Status` so the GUI can branch into
//     `DaemonStatusSheet` for the disabled-helper case.
//   - Is idempotent, so calling `register()` on every launch is
//     fine; macOS no-ops the second call when the helper is
//     already enabled.

import Foundation
import ServiceManagement

@MainActor
enum DaemonRegistration {
    /// The LaunchAgent plist embedded at
    /// `Contents/Library/LaunchAgents/<plistName>` in the .app
    /// bundle. Matches the bundle id convention `<host>.daemon`
    /// for the agent label.
    static let plistName = "com.deviceterm.daemon.plist"

    /// Read the current registration status without mutating
    /// system state. Wrapper around `SMAppService.agent.status`.
    static var status: SMAppService.Status {
        SMAppService.agent(plistName: plistName).status
    }

    /// Register the agent. Idempotent, so call it on every launch.
    /// Throws if launchd refuses (rare; typically signaling a
    /// signature problem).
    static func register() throws {
        try SMAppService.agent(plistName: plistName).register()
    }

    /// Unregister the agent. Used by tests + uninstall paths.
    static func unregister() throws {
        try SMAppService.agent(plistName: plistName).unregister()
    }

    /// Best-effort registration at first launch. Surfaces the
    /// macOS "Background Activity" notification once. If the
    /// register call throws, the caller can show
    /// `DaemonStatusSheet` to walk the user through enabling it
    /// in System Settings.
    static func registerOnFirstLaunch() throws {
        let service = SMAppService.agent(plistName: plistName)
        if service.status == .enabled { return }
        try service.register()
    }
}
