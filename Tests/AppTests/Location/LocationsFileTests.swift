// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Foundation
import Testing

// LocationsFileTests: the append-only, line-preserving contract.
//
// The rule these exist to protect is that deviceterm never destroys
// something a person typed into this file. It appends and nothing else:
// no reordering, no eviction, no rewriting of lines it didn't write,
// including lines it cannot even read.

private func tempLocationsPath() -> String {
    let dir = NSTemporaryDirectory() + "deviceterm-loctest-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir + "/locations"
}

private func write(_ contents: String, to path: String) throws {
    try contents.write(toFile: path, atomically: true, encoding: .utf8)
}

// MARK: - Reading

@Test("entries come back in file order")
func readsInFileOrder() throws {
    let path = tempLocationsPath()
    try write(
        """
        # saved locations
        37.7749,-122.4194 San Francisco
        51.5072,-0.1276 London
        64.1466,-21.9426
        """,
        to: path
    )
    let entries = LocationsFile(path: path).entries
    #expect(entries.map(\.label) == ["San Francisco", "London", nil])
    #expect(entries.first == .coordinate(latitude: 37.7749, longitude: -122.4194, label: "San Francisco"))
}

/// A missing file is the ordinary state of a fresh install, not a
/// failure: nothing saved yet.
@Test("a missing file is empty and not an error")
func missingFileIsEmpty() {
    let file = LocationsFile(path: tempLocationsPath())
    #expect(file.entries.isEmpty)
    #expect(!file.isUnreadable)
}

/// A file that exists but won't open is a real failure. Without the
/// distinction it would present as an empty section forever with
/// nothing anywhere saying why.
@Test("an unreadable file is distinguished from a missing one")
func unreadableFileIsFlagged() throws {
    let path = tempLocationsPath()
    // A directory where a file belongs: exists, cannot be read as text.
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    let file = LocationsFile(path: path)
    #expect(file.entries.isEmpty)
    #expect(file.isUnreadable)
}

// MARK: - The forward-compatibility rule

/// The load-bearing test. An append must preserve comments and
/// unrecognized lines verbatim.
@Test("an append preserves comments and unrecognized lines")
func appendPreservesEverythingElse() throws {
    let path = tempLocationsPath()
    let original = """
    # my locations
    37.7749,-122.4194 San Francisco

    # a route, hand-added
    ~/routes/commute.gpx
    ~/routes/marathon.gpx Boston Marathon

    # something a later version might write
    polygon 37.7749,-122.4194 51.5072,-0.1276
    """
    try write(original, to: path)

    let file = LocationsFile(path: path)
    // The coordinate and both routes are entries; the last line is not
    // a shape this version knows, and survives the write regardless.
    #expect(file.entries.count == 3)
    #expect(file.append(.coordinate(latitude: 51.5072, longitude: -0.1276, label: "London")))
    try file.save()

    let written = try String(contentsOfFile: path, encoding: .utf8)
    #expect(written.hasPrefix(original), "the original content was not preserved verbatim")
    #expect(written.contains("~/routes/commute.gpx"))
    #expect(written.contains("~/routes/marathon.gpx Boston Marathon"))
    #expect(written.contains("# my locations"))
    #expect(written.contains("polygon 37.7749,-122.4194 51.5072,-0.1276"))
    #expect(written.contains("51.507200,-0.127600 London"))
}

/// Nothing is ever removed to make room. A capped MRU would eventually
/// delete a line somebody typed by hand.
@Test("appending never evicts")
func appendNeverEvicts() throws {
    let path = tempLocationsPath()
    let file = LocationsFile(path: path)
    for index in 0..<50 {
        file.append(.coordinate(latitude: Double(index), longitude: 0, label: "P\(index)"))
    }
    try file.save()
    let reread = LocationsFile(path: path)
    #expect(reread.entries.count == 50)
    #expect(reread.entries.first?.label == "P0")
    #expect(reread.entries.last?.label == "P49")
}

// MARK: - Dedup

@Test("appending a location the file already lists changes nothing")
func duplicateAppendIsANoOp() throws {
    let path = tempLocationsPath()
    try write("37.774900,-122.419400 San Francisco", to: path)
    let file = LocationsFile(path: path)
    #expect(!file.append(.coordinate(latitude: 37.7749, longitude: -122.4194, label: nil)))
    try file.save()
    #expect(LocationsFile(path: path).entries.count == 1)
}

/// A duplicate leaves the existing line exactly as it was, including
/// the name the user chose, which the incoming entry must not overwrite.
@Test("a duplicate does not rewrite the existing label")
func duplicateKeepsTheUserLabel() throws {
    let path = tempLocationsPath()
    try write("37.774900,-122.419400 Home", to: path)
    let file = LocationsFile(path: path)
    file.append(.coordinate(latitude: 37.7749, longitude: -122.4194, label: "San Francisco"))
    try file.save()
    let written = try String(contentsOfFile: path, encoding: .utf8)
    #expect(written.contains("Home"))
    #expect(!written.contains("San Francisco"))
}

/// Dedup matches a hand-written line too, not just one deviceterm
/// wrote, so the file is compared by position rather than by text.
@Test("dedup matches a hand-written line at a different precision")
func dedupMatchesHandWrittenPrecision() throws {
    let path = tempLocationsPath()
    try write("37.7749,-122.4194 San Francisco", to: path)
    let file = LocationsFile(path: path)
    #expect(!file.append(.coordinate(latitude: 37.7749, longitude: -122.4194, label: nil)))
}

// MARK: - Seeding

/// A file that appeared on its own should explain itself, so the first
/// write to an empty file lays down a format header.
@Test("the first append seeds a documented header")
func firstAppendSeedsHeader() throws {
    let path = tempLocationsPath()
    let file = LocationsFile(path: path)
    file.append(.coordinate(latitude: 37.7749, longitude: -122.4194, label: "San Francisco"))
    try file.save()

    let written = try String(contentsOfFile: path, encoding: .utf8)
    #expect(written.contains("# deviceterm saved locations"))
    #expect(written.contains("37.774900,-122.419400 San Francisco"))
    // The header is documentation, not data.
    #expect(LocationsFile(path: path).entries.count == 1)
}

/// The header is written once. A second append must not stack another
/// copy on top of the file.
@Test("the header is not re-added on later appends")
func headerIsSeededOnce() throws {
    let path = tempLocationsPath()
    let first = LocationsFile(path: path)
    first.append(.coordinate(latitude: 1, longitude: 1, label: nil))
    try first.save()

    let second = LocationsFile(path: path)
    second.append(.coordinate(latitude: 2, longitude: 2, label: nil))
    try second.save()

    let written = try String(contentsOfFile: path, encoding: .utf8)
    let headerCount = written.components(separatedBy: "# deviceterm saved locations").count - 1
    #expect(headerCount == 1)
}

/// A file the user already started is theirs; deviceterm does not
/// prepend documentation to it.
@Test("a non-empty file is not given a header")
func existingFileKeepsItsShape() throws {
    let path = tempLocationsPath()
    try write("51.5072,-0.1276 London", to: path)
    let file = LocationsFile(path: path)
    file.append(.coordinate(latitude: 37.7749, longitude: -122.4194, label: nil))
    try file.save()
    let written = try String(contentsOfFile: path, encoding: .utf8)
    #expect(!written.contains("# deviceterm saved locations"))
    #expect(written.hasPrefix("51.5072,-0.1276 London"))
}

// MARK: - Preserving a file we can't read

/// Bytes that are not valid UTF-8: the realistic way to end up with a
/// locations file deviceterm can't decode, whether saved in another
/// encoding or corrupted by a stray byte.
private func writeUndecodable(to path: String) -> Data {
    var bytes: [UInt8] = Array("37.7749,-122.4194 Caf".utf8)
    bytes.append(0xE9)  // latin-1 'é'
    bytes.append(contentsOf: Array("\n51.5072,-0.1276 London\n".utf8))
    let data = Data(bytes)
    FileManager.default.createFile(atPath: path, contents: data)
    return data
}

/// The destructive case `isUnreadable` exists for. An undecodable file
/// reads as *zero* lines, which at the point of writing is
/// indistinguishable from an empty one: append would seed a header, add
/// one entry, and atomically replace a file full of the user's
/// locations. Atomicity makes that reliably destructive rather than
/// occasionally so.
@Test("saving refuses to overwrite a file that can't be decoded")
func saveRefusesOnUnreadableFile() throws {
    let path = tempLocationsPath()
    let original = writeUndecodable(to: path)

    let file = LocationsFile(path: path)
    #expect(file.isUnreadable)
    #expect(file.append(.coordinate(latitude: 1, longitude: 2, label: "New")))
    #expect(throws: LocationsFileError.unreadable(path: path)) {
        try file.save()
    }
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == original)
}

/// The store is what actually runs on the save path, so it has to leave
/// the file alone too rather than logging its way past the refusal.
@Test("the store leaves an undecodable file untouched")
func storeLeavesUnreadableFileIntact() async throws {
    let path = tempLocationsPath()
    let original = writeUndecodable(to: path)
    await LocationsFileStore(path: path)
        .record(.coordinate(latitude: 1, longitude: 2, label: "New"))
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == original)
}

// MARK: - The store

@Test("the store round-trips through the real file")
func storeRoundTrips() async {
    let store = LocationsFileStore(path: tempLocationsPath())
    #expect(await store.load().isEmpty)
    await store.record(
        .coordinate(latitude: 37.7749, longitude: -122.4194, label: "San Francisco")
    )
    #expect(await store.load().map(\.label) == ["San Francisco"])
    // Recording the same place twice leaves one row.
    await store.record(.coordinate(latitude: 37.7749, longitude: -122.4194, label: "Again"))
    #expect(await store.load().map(\.label) == ["San Francisco"])
}

/// The store opens the file fresh each call, so an edit made outside
/// deviceterm shows up on the next read with no cache to invalidate.
@Test("the store sees an external edit")
func storeSeesExternalEdits() async throws {
    let path = tempLocationsPath()
    let store = LocationsFileStore(path: path)
    await store.record(
        .coordinate(latitude: 37.7749, longitude: -122.4194, label: "San Francisco")
    )
    try write("51.5072,-0.1276 London", to: path)
    #expect(await store.load().map(\.label) == ["London"])
}

// MARK: - Concurrency

/// Saving is read, modify, write-the-whole-file. Run those concurrently
/// without a gate and both read the same original, so the second write
/// erases the first entry. Atomic replacement guarantees no *partial*
/// file and nothing at all about lost updates, and a lost save looks
/// exactly like one that never happened.
@Test("concurrent saves do not lose entries")
func concurrentSavesAllSurvive() async {
    let path = tempLocationsPath()
    let store = LocationsFileStore(path: path)
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<25 {
            group.addTask {
                await store.record(
                    .coordinate(latitude: Double(index), longitude: 0, label: "P\(index)")
                )
            }
        }
    }
    let labels = Set(await store.load().compactMap(\.label))
    #expect(labels == Set((0..<25).map { "P\($0)" }))
}

/// Each pane's view model holds its own store for the same file, so
/// serializing per store would not serialize anything that matters. The
/// gate has to be shared.
@Test("separate stores for one file still serialize")
func separateStoresShareTheGate() async {
    let path = tempLocationsPath()
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<25 {
            group.addTask {
                await LocationsFileStore(path: path).record(
                    .coordinate(latitude: Double(index), longitude: 0, label: "P\(index)")
                )
            }
        }
    }
    #expect(await LocationsFileStore(path: path).load().count == 25)
}
