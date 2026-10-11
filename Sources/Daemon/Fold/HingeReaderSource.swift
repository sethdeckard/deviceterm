// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Where a foldable's hinge angle is read from.
///
/// The guest helper is the reader every monitor starts with.
/// `devicectl device motion hinge-angle` is the fallback for a device the guest
/// reader cannot run on. The Xcode 27.1 RC's `devicectl` ships without the
/// `device motion` group, though CoreDevice still has the hinge action behind
/// it, so the fallback exists only where the installed `devicectl` has it.
enum HingeReaderSource: Equatable {
    /// The guest helper's `watch` mode, through `xcrun simctl spawn`.
    case guestHelper
    /// `xcrun devicectl device motion hinge-angle`.
    case devicectl

    /// Whether the installed `devicectl` can read the hinge, asked once per
    /// daemon and only when a monitor first wants to fall back. An Xcode update
    /// that restores the command is picked up on the next daemon start.
    static let devicectlAvailable: Bool = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["devicectl", "device", "motion", "--help"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return false }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return devicectlHasHingeAngle(helpOutput: String(data: output, encoding: .utf8) ?? "")
    }()

    /// Whether a `devicectl device motion --help` output lists the hinge
    /// reader.
    ///
    /// A `devicectl` without the group prints the `device` help instead, which
    /// names no `hinge-angle`.
    static func devicectlHasHingeAngle(helpOutput: String) -> Bool {
        helpOutput.contains("hinge-angle")
    }
}
