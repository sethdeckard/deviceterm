// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import Testing

private func locateE2EHelper(_ name: String) -> URL? {
    let testFile = URL(fileURLWithPath: #filePath)
    var current = testFile.deletingLastPathComponent()
    for _ in 0..<8 {
        let candidate = current.appendingPathComponent(
            ".agents/skills/deviceterm-e2e/helpers/\(name)"
        )
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        let parent = current.deletingLastPathComponent()
        if parent.path == current.path { return nil }
        current = parent
    }
    return nil
}

@Test
func e2ePreflightProbesTheCaptureWireMethod() throws {
    let url = try #require(
        locateE2EHelper("preflight.sh"),
        "deviceterm-e2e preflight not found relative to test source"
    )
    let contents = try String(contentsOf: url, encoding: .utf8)
    let wirePattern = RPCMethod.paneCaptureText.rawValue
        .replacingOccurrences(of: ".", with: "\\.")

    #expect(contents.contains("\"\(wirePattern)\""))
    #expect(!contents.contains("pane\\.capture-text"))
    #expect(contents.contains("DEVICETERM_SESSION unset — run this preflight inside"))
}

@Test
func e2eTabPillHelperRejectsAWindowlessCycleDump() throws {
    let helper = try #require(
        locateE2EHelper("tab-pills.sh"),
        "deviceterm-e2e tab-pills helper not found relative to test source"
    )
    let axDump = try #require(locateE2EHelper("ax-dump.sh"))
    let axDumpContents = try String(contentsOf: axDump, encoding: .utf8)
    #expect(axDumpContents.contains("DeviceTerm dump contains no AXWindow"))

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("deviceterm-e2e-helper-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let dump = directory.appendingPathComponent("windowless.json")
    let contents = #"""
    {"ok":true,"unreadable":false,"truncated":false,"tree":{"role":"AXApplication","children":[
      {"role":"AXApplication","cycle":true,"children":[]},
      {"role":"AXMenuBar","children":[]}
    ]}}
    """#
    try Data(contents.utf8).write(to: dump)

    let stderr = Pipe()
    let process = Process()
    process.executableURL = helper
    process.arguments = [dump.path]
    process.standardOutput = Pipe()
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()

    let error = try #require(
        String(bytes: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    )
    #expect(process.terminationStatus != 0)
    #expect(error.contains("contains no AXWindow"))
}
