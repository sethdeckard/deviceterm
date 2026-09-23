// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Foundation
import Testing

// AutomationProgramsFileTests: reading the file, and the difference
// between a file that isn't there and one that won't decode.
//
// Absent is the ordinary state and means nothing is configured, so it
// must look exactly like the feature not existing. A file that exists and
// cannot be read is a real failure that would otherwise present as
// "nothing configured" forever with nothing anywhere saying why.

private func tempProgramsPath() -> String {
    let dir = NSTemporaryDirectory() + "deviceterm-autoprog-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir + "/automation-programs"
}

private func write(_ contents: String, to path: String) throws {
    try contents.write(toFile: path, atomically: true, encoding: .utf8)
}

@Test("blocks come back in file order")
func readsBlocksInFileOrder() throws {
    let path = tempProgramsPath()
    try write(
        """
        # automation programs
        program build-bridge
          command ~/.local/bin/build-bridge
          restart false

        program watcher
          command ~/bin/watch-builds
        """,
        to: path
    )
    let file = AutomationProgramsFile(path: path)
    #expect(file.defects.isEmpty)
    #expect(file.entries.map(\.name) == ["build-bridge", "watcher"])
    #expect(file.entries.map(\.restart) == [false, true])
}

/// A trailing newline is the normal shape of a hand-edited file and must
/// not read as an extra, empty line.
@Test("a trailing newline adds no line")
func toleratesTrailingNewline() throws {
    let path = tempProgramsPath()
    try write("program p\n  command run\n", to: path)
    #expect(AutomationProgramsFile(path: path).entries.map(\.name) == ["p"])
}

/// This is the whole of acceptance for "nothing configured": no entries,
/// nothing to report, and so nothing for the coordinator to dispatch.
@Test("a missing file is empty and not a defect")
func missingProgramsFileIsEmpty() {
    let file = AutomationProgramsFile(path: tempProgramsPath())
    #expect(file.entries.isEmpty)
    #expect(file.defects.isEmpty)
}

@Test("an unreadable file is distinguished from a missing one")
func unreadableFileIsReported() throws {
    let path = tempProgramsPath()
    // A directory where a file belongs: exists, cannot be read as text.
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    let file = AutomationProgramsFile(path: path)
    #expect(file.entries.isEmpty)
    #expect(file.defects.map(\.reason) == [.unreadableFile])
}

@Test("a cwd resolves against the file's own directory")
func resolvesCwdAgainstFileDirectory() throws {
    let path = tempProgramsPath()
    try write("program p\n  command run\n  cwd sub\n", to: path)
    let directory = (path as NSString).deletingLastPathComponent
    #expect(
        AutomationProgramsFile(path: path).entries.first?.cwd
            == (directory as NSString).appendingPathComponent("sub")
    )
}

@Test("defects from the file reach the reader")
func surfacesParseDefects() throws {
    let path = tempProgramsPath()
    try write("program p\n  cwd /tmp\n", to: path)
    let file = AutomationProgramsFile(path: path)
    #expect(file.entries.isEmpty)
    #expect(file.defects.map(\.reason) == [.missingCommand])
}
