// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Where a foldable's hinge angle is read from.
///
/// `devicectl device motion hinge-angle` is Apple's own reader and the one to
/// prefer. The Xcode 27.1 RC's `devicectl` ships without the `device motion`
/// group, though CoreDevice still has the hinge action behind it, so when the
/// installed `devicectl` lacks it the guest helper reads the hinge instead.
enum HingeReaderSource: Equatable {
    /// `xcrun devicectl device motion hinge-angle`.
    case devicectl
    /// The guest helper's `watch` mode, through `xcrun simctl spawn`.
    case guestHelper

    /// The source this host supports, asked of the installed `devicectl` once
    /// per daemon. An Xcode update that restores the command is picked up on
    /// the next daemon start.
    static let installed: HingeReaderSource = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["devicectl", "device", "motion", "--help"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return .guestHelper }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return detect(helpOutput: String(data: output, encoding: .utf8) ?? "")
    }()

    /// The source a `devicectl device motion --help` output implies.
    ///
    /// A `devicectl` without the group prints the `device` help instead, which
    /// names no `hinge-angle`.
    static func detect(helpOutput: String) -> HingeReaderSource {
        helpOutput.contains("hinge-angle") ? .devicectl : .guestHelper
    }
}
