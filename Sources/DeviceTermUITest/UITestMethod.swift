// SPDX-License-Identifier: GPL-3.0-or-later
//
// The request/reply vocabulary the UI-test harness vends over its own
// private Unix-domain socket.
//
// Deliberately separate from `DaemonProtocol.RPCMethod`: the harness is
// a test *instrument* that screenshots and drives deviceterm from the
// outside, not a deviceterm RPC peer. Its method set stays decoupled
// from the daemon's wire contract. The only thing borrowed from
// `DaemonProtocol` is the length-prefixed framing (`RPCFraming`) and the
// client socket primitive (`UDSClientSocket`), both Foundation-only.

import Foundation

/// The methods a client may ask the resident harness to perform.
///
/// Raw values are the on-the-wire method names.
public enum UITestMethod: String, Codable, Sendable, CaseIterable, Equatable {
    /// Liveness probe: confirms a resident harness is answering.
    case ping
    /// Screenshot the frontmost content window of the requested bundle
    /// identifier (composited pixels) → PNG. Never a whole display.
    case captureWindow = "capture.window"
    /// Screenshot just the daemon's menu-bar status item window → PNG, or
    /// report it absent (which is how "hidden at zero owned sims" reads).
    case captureStatusItem = "capture.status-item"
    /// Walk an app's AppKit accessibility tree → JSON.
    case axDump = "ax.dump"
    /// Post a keyboard shortcut (a GUI-only gesture with no CLI path).
    case driveKey = "drive.key"
    /// Click at a point or on an AX element.
    case driveClick = "drive.click"
    /// Report resident + TCC-grant health (client-side check + probe).
    case doctor
}
