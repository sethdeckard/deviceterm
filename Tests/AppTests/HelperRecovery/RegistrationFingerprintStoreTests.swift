// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Foundation
import Testing

/// The record of which LaunchAgent plist the helper was last registered with.
///
/// Only a clean "no such file" may read as no record. Anything else throws, so
/// a record the launch couldn't read is never taken for a stale one.
struct RegistrationFingerprintStoreTests {
    private func makeStore() -> (store: RegistrationFingerprintStore, path: String) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("deviceterm-fingerprint-\(UUID().uuidString)")
            .appendingPathComponent("registration-plist-sha256")
            .path
        return (RegistrationFingerprintStore(path: path), path)
    }

    @Test
    func aFreshStoreHasNoRecord() throws {
        let (store, _) = makeStore()
        #expect(try store.recorded() == nil)
    }

    @Test
    func aRecordedFingerprintReadsBack() throws {
        let (store, path) = makeStore()
        try store.record("abc123")
        #expect(try store.recorded() == "abc123")
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test
    func anUnreadableRecordThrowsRatherThanReadingAsMissing() throws {
        let (store, path) = makeStore()
        // A directory where the file should be: present, but not readable as one.
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try store.recorded() }
    }

    @Test
    func theFingerprintIsTheSHA256OfThePlistBytes() {
        // SHA-256 of the empty input.
        let empty = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        #expect(RegistrationFingerprintStore.fingerprint(of: Data()) == empty)
        #expect(RegistrationFingerprintStore.fingerprint(of: Data("a".utf8)) != empty)
    }

    @Test
    func aBundleWithoutTheAgentPlistHasNone() {
        let bundle = Bundle(path: FileManager.default.temporaryDirectory.path) ?? .main
        let name = "missing-\(UUID().uuidString).plist"
        #expect(RegistrationFingerprintStore.embeddedPlist(named: name, in: bundle) == nil)
    }
}
