// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Darwin
import Foundation
import Testing

/// Whether a helper process is running, from a scan of this user's processes.
///
/// The property that matters: only a complete scan that finds no helper reads
/// as not running, because that answer licenses rebuilding the registration.
/// Anything ambiguous must read as possibly running.
struct HelperPresenceTests {
    @Test("the scan's sightings decide presence", arguments: [
        ([HelperPresence.Sighting](), HelperPresence.notRunning),
        ([.path("/bin/zsh"), .path("/usr/bin/login")], .notRunning),
        ([.path("/bin/zsh"), .path("/A/B.app/Contents/MacOS/deviceterm-daemon")], .running),
        ([.path("/bin/zsh"), .unreadable], .unknown),
        ([.unreadable, .path("/X/deviceterm-daemon")], .running),
        ([.path("/bin/deviceterm-daemon-old")], .notRunning),
        // A binary replaced after launch leaves only the name.
        ([.name("codex"), .name("SourceKitService")], .notRunning),
        ([.name("codex"), .name("deviceterm-daemon")], .running),
        ([.name("deviceterm-daemo")], .notRunning)
    ])
    func classifiesTheScan(sightings: [HelperPresence.Sighting], expected: HelperPresence) {
        #expect(HelperPresence.classify(sightings, executableName: "deviceterm-daemon") == expected)
    }

    @Test
    func aNameCutShortAtTheLimitStillMatches() {
        // `proc_name` returns at most 31 bytes for a longer executable name.
        let long = String(repeating: "h", count: 40)
        let cut = String(long.prefix(31))
        #expect(HelperPresence.isHelper(.name(cut), executableName: long))
        #expect(!HelperPresence.isHelper(.name(String(cut.dropLast())), executableName: long))
    }

    @Test
    func theExecutableNameComesFromTheAgentPlistsBundleProgram() throws {
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["BundleProgram": "Contents/Library/LoginItems/h.app/Contents/MacOS/helper-x"],
            format: .xml,
            options: 0
        )
        #expect(HelperPresence.executableName(fromAgentPlist: plist) == "helper-x")
        #expect(HelperPresence.executableName(fromAgentPlist: Data("not a plist".utf8)) == nil)
    }

    @Test
    func aRunningProcessIsFoundByItsExecutableName() throws {
        // This test's own process is a live process of this user.
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(getpid(), &buffer, UInt32(buffer.count))
        try #require(length > 0)
        let path = try #require(String(bytes: buffer.prefix(Int(length)), encoding: .utf8))
        let name = (path as NSString).lastPathComponent
        #expect(HelperPresence.probe(executableName: name) == .running)
        #expect(HelperPresence.probe(executableName: "no-such-helper-\(UUID().uuidString)") != .running)
    }

    @Test
    func aListThatFillsItsBufferIsRetriedWithMoreRoom() {
        // 70 processes exist; the size query claims 1, so the first buffer
        // (65 slots) fills and must not be trusted.
        let all = (1...70).map { pid_t($0) }
        var calls = 0
        let pids = HelperPresence.completeList { buffer, bytes in
            calls += 1
            let stride = Int32(MemoryLayout<pid_t>.stride)
            guard let buffer else { return stride }
            let fit = min(all.count, Int(bytes / stride))
            buffer.withMemoryRebound(to: pid_t.self, capacity: fit) { out in
                for index in 0..<fit { out[index] = all[index] }
            }
            return Int32(fit) * stride
        }
        #expect(pids == all)
        #expect(calls == 3)
    }

    @Test
    func aListThatAlwaysFillsItsBufferGivesUp() {
        let pids = HelperPresence.completeList { _, bytes in
            bytes == 0 ? Int32(MemoryLayout<pid_t>.stride) : bytes
        }
        #expect(pids == nil)
    }
}
