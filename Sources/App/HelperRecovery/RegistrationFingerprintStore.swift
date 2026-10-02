// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation

/// Reads and writes the fingerprint of the LaunchAgent plist the helper was
/// last registered with.
///
/// launchd keeps the scheduling policy a job was registered with, and an
/// ordinary launch doesn't rebuild an enabled registration, so a changed plist
/// would otherwise never reach an existing install. Comparing this record with
/// the embedded plist is how a launch notices its registration is stale.
///
/// A value type over a path so a test can point it at a temporary directory.
/// It lives in Application Support beside `RegistrationRepairStore`'s marker.
/// Only a clean "no such file" reads as no record; any other failure throws, so
/// a caller can't mistake a record it couldn't read for a stale one.
struct RegistrationFingerprintStore {
    private let path: String

    init(path: String) {
        self.path = path
    }

    private static func isNoSuchFile(_ error: NSError) -> Bool {
        guard error.domain == NSCocoaErrorDomain else { return false }
        return error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError
    }

    /// `~/Library/Application Support/deviceterm/registration-plist-sha256`.
    static func standard() throws -> RegistrationFingerprintStore {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return RegistrationFingerprintStore(
            path: support.appendingPathComponent("deviceterm/registration-plist-sha256").path
        )
    }

    /// The LaunchAgent plist embedded at `Contents/Library/LaunchAgents/<name>`
    /// in `bundle`, the file `SMAppService.agent(plistName:)` registers.
    static func embeddedPlist(named name: String, in bundle: Bundle = .main) -> Data? {
        let url = bundle.bundleURL
            .appendingPathComponent("Contents/Library/LaunchAgents")
            .appendingPathComponent(name)
        return try? Data(contentsOf: url)
    }

    /// The SHA-256 of `plist` as lowercase hex.
    static func fingerprint(of plist: Data) -> String {
        SHA256.hash(data: plist).map { String(format: "%02x", $0) }.joined()
    }

    /// The recorded fingerprint, or nil when none has been recorded.
    func recorded() throws -> String? {
        do {
            return try String(contentsOfFile: path, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error as NSError where Self.isNoSuchFile(error) {
            return nil
        }
    }

    /// Record `fingerprint`. Call only after a registration with that plist
    /// succeeded, so a failed one is retried on a later launch.
    func record(_ fingerprint: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(fingerprint.utf8).write(to: url, options: .atomic)
    }
}
