// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import Testing

// LaunchAgent plist drift guard. The file `Contents/Library/
// LaunchAgents/com.deviceterm.daemon.plist` is what
// `SMAppService.agent(plistName:)` reads at registration time;
// the `MachServices` top-level key has to match
// `MachServiceName.daemon` exactly (the daemon binds the
// listener under that name and the GUI connects to it). The plist
// also encodes the `BundleProgram`, label, KeepAlive policy, and
// associated bundle ids. All are load-bearing and worth pinning.

private struct LaunchAgentPlist: Decodable {
    enum CodingKeys: String, CodingKey {
        case label = "Label"
        case bundleProgram = "BundleProgram"
        case associatedBundleIdentifiers = "AssociatedBundleIdentifiers"
        case machServices = "MachServices"
        case runAtLoad = "RunAtLoad"
        case keepAlive = "KeepAlive"
        case processType = "ProcessType"
    }

    let label: String
    let bundleProgram: String
    let associatedBundleIdentifiers: [String]
    let machServices: [String: Bool]
    let runAtLoad: Bool
    let keepAlive: LaunchAgentKeepAlive
    let processType: String
}

private struct LaunchAgentKeepAlive: Decodable {
    enum CodingKeys: String, CodingKey {
        case successfulExit = "SuccessfulExit"
    }

    let successfulExit: Bool
}

private enum LaunchAgentPlistError: Error {
    case notFound
}

private func locatePlist() throws -> URL {
    // Walk up from this source file until we hit the repo root,
    // then resolve the canonical plist path. Avoids SwiftPM
    // resource bundling for a test that needs to read the
    // *committed* file, not a copy.
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while directory.path != "/" {
        let candidate = directory
            .appendingPathComponent("Sources")
            .appendingPathComponent("App")
            .appendingPathComponent("Resources")
            .appendingPathComponent("LaunchAgents")
            .appendingPathComponent("com.deviceterm.daemon.plist")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        directory = directory.deletingLastPathComponent()
    }
    throw LaunchAgentPlistError.notFound
}

@Test
func launchAgentPlistShapeIsValid() throws {
    let url = try locatePlist()
    let data = try Data(contentsOf: url)
    let plist = try PropertyListDecoder().decode(
        LaunchAgentPlist.self,
        from: data
    )
    #expect(plist.label == "com.deviceterm.daemon")
    #expect(plist.bundleProgram == "Contents/Library/LoginItems/"
        + "deviceterm-daemon.app/Contents/MacOS/deviceterm-daemon")
    #expect(plist.associatedBundleIdentifiers == ["com.deviceterm"])
    #expect(plist.runAtLoad == false)
    #expect(plist.keepAlive.successfulExit == false)
    #expect(plist.processType == "Background")
}

@Test
func machServicesKeyMatchesConstant() throws {
    let url = try locatePlist()
    let data = try Data(contentsOf: url)
    let plist = try PropertyListDecoder().decode(
        LaunchAgentPlist.self,
        from: data
    )
    // The drift guard: the plist's MachServices top-level key
    // must equal `MachServiceName.daemon` verbatim. A rename in
    // one place without the other breaks the GUI ↔ daemon
    // handshake silently.
    #expect(plist.machServices.keys.contains(MachServiceName.daemon))
    #expect(plist.machServices[MachServiceName.daemon] == true)
}
