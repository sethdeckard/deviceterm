// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import DaemonProtocol
import Foundation

/// Compiles `FoldHelperSource` for the simulator and caches the result.
///
/// The helper has to be an arm64-iphonesimulator binary, so it cannot ship
/// inside a macOS app bundle. Building it on first use keeps the distribution
/// a pure macOS bundle and costs one `clang` invocation rather than one per
/// fold. Cached by source content and the selected developer-directory path;
/// an Xcode updated in place keeps that path, so it does not invalidate the
/// cache.
///
/// Building needs the same Xcode the rest of the daemon already needs for
/// CoreSimulator, so this adds no dependency the pane path didn't have. A
/// subprocess that cannot be launched reports `.toolchainUnavailable`; one
/// that launches and exits non-zero, which is what a missing compiler or SDK
/// looks like, reports `.compileFailed` carrying its output. The fold verb
/// refuses on either rather than crashing.
///
/// `@unchecked Sendable`: the serial queue protects every access to
/// `cachedPath` and serializes builds within this instance.
final class FoldHelperBuilder: @unchecked Sendable {
    /// Where the built helper lands, and what invalidates it.
    ///
    /// Keyed on the source *and* the selected developer directory, because a
    /// toolchain change can alter the produced binary and a stale one would be
    /// spawned against a runtime it was not built for. The directory is the
    /// one in effect, resolved through `xcode-select` when `DEVELOPER_DIR` is
    /// unset, which it usually is: keying on the variable alone would leave
    /// the toolchain arm empty on almost every host and invalidate nothing.
    /// The source arm is a content hash, so a daemon update that edits the
    /// program rebuilds without anyone clearing a cache.
    struct CacheKey: Equatable {
        let sourceHash: String
        let developerDirectory: String
    }

    /// `LocalizedError`, not a bare `Error`: the daemon reports a failed
    /// fold by reading `localizedDescription`, and a plain Swift enum
    /// bridges to a generic one. Without this the clang or codesign output,
    /// the only thing that says *why* the build failed, is dropped on the
    /// way to the caller.
    enum Failure: LocalizedError, Equatable {
        case toolchainUnavailable(String)
        case compileFailed(String)

        var errorDescription: String? {
            switch self {
            case let .toolchainUnavailable(detail):
                return "the fold helper could not be built: \(detail)"

            case let .compileFailed(detail):
                return "the fold helper failed to build: \(detail)"
            }
        }
    }

    private static let runProcessDefault: @Sendable (String, [String]) throws
        -> (status: Int32, output: String) = { executable, arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw Failure.toolchainUnavailable("\(executable) could not be run: \(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        }

    private let environment: [String: String]
    private let runProcess: @Sendable (String, [String]) throws -> (status: Int32, output: String)
    /// Serializes `cachedPath` and the build behind it, so two folds
    /// arriving together produce one compile rather than two.
    private let queue = DispatchQueue(label: "com.deviceterm.daemon.fold-helper")
    private var cachedPath: String?

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        runProcess: (@Sendable (String, [String]) throws -> (status: Int32, output: String))? = nil
    ) {
        self.environment = environment
        self.runProcess = runProcess ?? FoldHelperBuilder.runProcessDefault
    }

    /// The cache key for the current source and toolchain.
    ///
    /// Asks `xcode-select` when `DEVELOPER_DIR` is unset. That costs one
    /// subprocess, paid once per builder: `helperBinary()` only reaches here
    /// when it has no path cached yet.
    func cacheKey() -> CacheKey {
        let digest = SHA256.hash(data: Data(FoldHelperSource.code.utf8))
        var developerDirectory = environment["DEVELOPER_DIR"] ?? ""
        if developerDirectory.isEmpty,
            let selected = try? runProcess("/usr/bin/xcode-select", ["-p"]),
            selected.status == 0 {
            developerDirectory = selected.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return CacheKey(
            sourceHash: String(digest.map { String(format: "%02x", $0) }.joined().prefix(16)),
            developerDirectory: developerDirectory
        )
    }

    /// Absolute path the built helper occupies for a given key.
    func binaryPath(for key: CacheKey) -> String {
        let directory = (XDGPaths.cacheHome(environment: environment) as NSString)
            .appendingPathComponent("deviceterm/fold-helper")
        let toolchainDigest = SHA256.hash(data: Data(key.developerDirectory.utf8))
        let toolchainHex = toolchainDigest.map { String(format: "%02x", $0) }.joined()
        let toolchain = key.developerDirectory.isEmpty ? "default" : String(toolchainHex.prefix(8))
        return (directory as NSString)
            .appendingPathComponent("fold-helper-\(key.sourceHash)-\(toolchain)")
    }

    /// The helper binary, building it if this source and toolchain have not
    /// produced one yet. Repeated calls return the cached path without
    /// touching the filesystem.
    func helperBinary() throws -> String {
        try queue.sync {
            if let cachedPath { return cachedPath }

            let path = binaryPath(for: cacheKey())
            if FileManager.default.isExecutableFile(atPath: path) {
                cachedPath = path
                return path
            }
            try build(at: path)
            cachedPath = path
            return path
        }
    }

    /// Compile and ad-hoc sign into `path`.
    ///
    /// Everything this writes before the final move carries a per-build
    /// suffix. `queue` serializes only this builder, and a pane holds its
    /// own, so two panes folding for the first time together run two builds
    /// against one cache directory; shared scratch paths would let one
    /// delete or move the other's half-written file. The publish is a
    /// rename, which is atomic, so the loser simply overwrites with an
    /// identical binary.
    private func build(at path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        let build = UUID().uuidString.prefix(8)
        let source = (directory as NSString)
            .appendingPathComponent("fold-helper-\(build).c")
        try FoldHelperSource.code.write(toFile: source, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: source) }

        let staging = path + ".building-\(build)"
        let compile = try runProcess("/usr/bin/xcrun", [
            "-sdk", "iphonesimulator", "clang",
            "-arch", "arm64",
            "-O2",
            "-o", staging,
            source,
            "-framework", "CoreFoundation",
            "-framework", "IOKit"
        ])
        guard compile.status == 0 else {
            throw Failure.compileFailed(compile.output.isEmpty
                ? "clang exited \(compile.status)"
                : compile.output)
        }
        // Spawning into the simulator needs a signature; ad-hoc is enough and
        // needs no identity on the machine.
        let sign = try runProcess("/usr/bin/codesign", ["-f", "-s", "-", staging])
        guard sign.status == 0 else {
            try? FileManager.default.removeItem(atPath: staging)
            throw Failure.compileFailed(sign.output.isEmpty
                ? "codesign exited \(sign.status)"
                : sign.output)
        }
        // `rename` rather than remove-then-move: it replaces in one step, so
        // a second builder racing this one never sees the destination absent
        // and never fails because it already exists. Both produce the same
        // bytes, so whichever lands last is the one everyone runs.
        guard rename(staging, path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? FileManager.default.removeItem(atPath: staging)
            throw Failure.compileFailed("could not publish the helper: \(reason)")
        }
    }
}
