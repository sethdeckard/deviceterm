// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
import Darwin
import Foundation
import Testing

private let xcodeAppDeveloperDir = "/Applications/Xcode.app/Contents/Developer"
private let xcodeAppFrameworkPath =
    "/Applications/Xcode.app/Contents/Developer"
    + "/Library/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"
private let systemFrameworkPath =
    "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"
private let profilesFrameworkPath =
    "/Library/Developer/CoreSimulator/Profiles"
    + "/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"
private let developerDirectoryCacheChildKey =
    "DEVICETERM_TEST_DEVELOPER_DIRECTORY_CACHE_CHILD"
private let developerDirectoryCacheFilter =
    "developerDirectoryResolutionIsStableForProcessLifetime"

/// True iff the host is *fully* CoreSimulator-compatible per the probe:
/// not just "framework loadable," but every required class/selector/
/// protocol the bridge depends on is also present. Used to gate
/// integration tests so the unit suite stays runnable on every degraded
/// host: no Xcode at all, mismatched Xcode whose private selectors have
/// drifted, CI runners without simulators.
///
/// The probe binary (`make probe` / `deviceterm-probe`) remains the
/// user-facing compatibility gate. The test suite never doubles as that
/// gate: if the probe doesn't pass, the live tests skip rather than
/// fail.
///
/// Evaluated once at discovery time; the dispatch_once inside the loader
/// makes the cost a single dlopen attempt regardless of how many tests
/// reference this flag.
private let coreSimulatorAvailable: Bool = {
    CoreSimulatorLoader.probe().ok
}()

// MARK: - Pure: candidate framework paths

@Test
func candidatePathsLeadWithDeveloperDir() {
    let paths = CoreSimulatorLoader.candidateFrameworkPaths(forDeveloperDir: xcodeAppDeveloperDir)
    #expect(paths.first == xcodeAppFrameworkPath)
}

@Test
func candidatePathsIncludeSystemLevel() {
    let paths = CoreSimulatorLoader.candidateFrameworkPaths(forDeveloperDir: xcodeAppDeveloperDir)
    #expect(paths.contains(systemFrameworkPath))
    #expect(paths.contains(profilesFrameworkPath))
}

@Test
func candidatePathsIncludeHistoricalFallback() {
    // Even when xcode-select points elsewhere, the historical Xcode.app path
    // is included as a last-resort fallback.
    let paths = CoreSimulatorLoader.candidateFrameworkPaths(
        forDeveloperDir: "/Volumes/Xcode15/Xcode.app/Contents/Developer"
    )
    #expect(paths.contains(xcodeAppFrameworkPath))
}

@Test
func candidatePathsDeDupeWhenDeveloperDirIsHistorical() {
    // When DEVELOPER_DIR happens to equal the historical default, the
    // historical fallback shouldn't appear twice.
    let paths = CoreSimulatorLoader.candidateFrameworkPaths(forDeveloperDir: xcodeAppDeveloperDir)
    let count = paths.filter { $0 == xcodeAppFrameworkPath }.count
    #expect(count == 1, "historical fallback appeared \(count) times")
}

@Test
func candidatePathsWithEmptyDeveloperDirReturnsSystemFallbacks() {
    let paths = CoreSimulatorLoader.candidateFrameworkPaths(forDeveloperDir: "")
    // No developer-dir-derived entry, but the system + historical fallbacks
    // are still present.
    #expect(!paths.isEmpty)
    #expect(paths.contains(systemFrameworkPath))
}

@Test
func developerDirectoryResolutionIsStableForProcessLifetime() throws {
    if ProcessInfo.processInfo.environment[developerDirectoryCacheChildKey] != "1" {
        let arguments = CommandLine.arguments
        let bundleFlagIndex = try #require(
            arguments.firstIndex(of: "--test-bundle-path")
        )
        let testBinaryIndex = arguments.index(after: bundleFlagIndex)
        let testBinary = try #require(
            arguments.indices.contains(testBinaryIndex)
                ? arguments[testBinaryIndex]
                : nil
        )
        let child = Process()
        child.executableURL = URL(fileURLWithPath: arguments[0])
        child.arguments = [
            "--test-bundle-path", testBinary,
            "--filter", developerDirectoryCacheFilter,
            testBinary,
            "--testing-library", "swift-testing",
        ]
        var environment = ProcessInfo.processInfo.environment
        environment[developerDirectoryCacheChildKey] = "1"
        child.environment = environment
        try child.run()
        child.waitUntilExit()
        #expect(child.terminationReason == .exit)
        #expect(child.terminationStatus == 0)
        return
    }

    let resolved = CoreSimulatorLoader.resolveDeveloperDir()
    let initialProbe = CoreSimulatorLoader.probe()
    let original = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
    let sentinel = "/tmp/deviceterm-developer-dir-\(UUID().uuidString)"
    defer {
        if let original {
            setenv("DEVELOPER_DIR", original, 1)
        } else {
            unsetenv("DEVELOPER_DIR")
        }
    }

    #expect(setenv("DEVELOPER_DIR", sentinel, 1) == 0)
    #expect(CoreSimulatorLoader.resolveDeveloperDir() == resolved)
    let mutatedProbe = CoreSimulatorLoader.probe()
    #expect(mutatedProbe.developerDir == resolved)
    #expect(mutatedProbe.xcodeVersion == initialProbe.xcodeVersion)
}

// MARK: - Integration: live framework load + probe
//
// These hit the host's actual CoreSimulator install. Gated on
// `coreSimulatorAvailable` so the unit suite stays runnable on hosts
// without Xcode (and so the probe, not these tests, remains the
// compatibility gate).

@Test(.disabled(if: !coreSimulatorAvailable, "CoreSimulator not available on host"))
func liveLoadSucceedsOnDeveloperHost() throws {
    try CoreSimulatorLoader.loadFramework()
    let resolved = CoreSimulatorLoader.resolvedFrameworkPath
    #expect(resolved != nil)
    #expect(resolved?.hasSuffix("CoreSimulator.framework/CoreSimulator") == true)
}

@Test(.disabled(if: !coreSimulatorAvailable, "CoreSimulator not available on host"))
func liveProbeIsOkOnDeveloperHost() {
    let report = CoreSimulatorLoader.probe()
    #expect(report.ok, "probe should pass on a developer host; missing=\(report.missingSymbols)")
    #expect(!report.frameworkPath.isEmpty)
    #expect(!report.macOSVersion.isEmpty)
    #expect(!report.developerDir.isEmpty)
    #expect(report.missingSymbols.isEmpty)
}

@Test(.disabled(if: !coreSimulatorAvailable, "CoreSimulator not available on host"))
func probeIsIdempotent() {
    let first = CoreSimulatorLoader.probe()
    let second = CoreSimulatorLoader.probe()
    #expect(first.ok == second.ok)
    #expect(first.okSymbols.count == second.okSymbols.count)
    #expect(first.missingSymbols.count == second.missingSymbols.count)
}

// On a degraded host (no framework OR framework with drifted selectors),
// confirm the loader/probe report the failure cleanly with a populated
// missingSymbols list instead of crashing. This is the contract the
// integration tests above rely on for graceful skipping. Either kind of
// failure is a valid degraded state: frameworkPath could be `""` (no
// framework) or set (framework loaded, selectors missing).
@Test(.disabled(if: coreSimulatorAvailable, "only meaningful on hosts where the probe doesn't pass"))
func probeReportsFailureGracefully() {
    let report = CoreSimulatorLoader.probe()
    #expect(!report.ok)
    #expect(!report.missingSymbols.isEmpty)
}
