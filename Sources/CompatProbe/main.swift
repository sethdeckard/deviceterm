// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
import Foundation

// deviceterm-probe: CoreSimulator compatibility probe.
//
// Runs CoreSimulatorLoader.probe() against the host's CoreSimulator
// framework, prints a structured report, and (when invoked from the
// repo root) appends a line to the git-ignored probe-runs.log. Exits 0
// if every required symbol was found, 1 otherwise. The curated
// compatibility ledger is as-tested.md's required-symbols table; this
// log is just a local "did it still resolve?" trail, not kept in git.

let report = CoreSimulatorLoader.probe()

let line = String(repeating: "─", count: 64)
print(line)
print("deviceterm CoreSimulator compatibility probe")
print(line)
print("macOS:           \(report.macOSVersion)")
print("Xcode:           \(report.xcodeVersion.split(separator: "\n").joined(separator: " | "))")
print("DEVELOPER_DIR:   \(report.developerDir)")
print("Framework path:  \(report.frameworkPath.isEmpty ? "(not loaded)" : report.frameworkPath)")
print(line)
print("OK symbols (\(report.okSymbols.count)):")
for sym in report.okSymbols { print("  ✓ \(sym)") }
print(line)
print("Missing symbols (\(report.missingSymbols.count)):")
for sym in report.missingSymbols { print("  ✗ \(sym)") }
print(line)

let verdict = report.ok
    ? "OK: deviceterm can drive CoreSimulator on this Xcode"
    : "FAIL: see missing symbols above"
print("Verdict: \(verdict)")
print(line)

// Best-effort: a log that can't be written never fails the probe.
let cwd = FileManager.default.currentDirectoryPath
if FileManager.default.fileExists(atPath: "\(cwd)/Package.swift") {
    let logPath = "\(cwd)/probe-runs.log"
    let dateString = ISO8601DateFormatter().string(from: Date())
    let xcodeShort = report.xcodeVersion.split(separator: "\n").first.map(String.init) ?? ""
    let resultStr = report.ok
        ? "OK"
        : "MISSING: \(report.missingSymbols.joined(separator: "; "))"
    let entry = "\(dateString)  macOS \(report.macOSVersion)  \(xcodeShort)  \(resultStr)\n"
    if !FileManager.default.fileExists(atPath: logPath) {
        FileManager.default.createFile(atPath: logPath, contents: nil)
    }
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(Data(entry.utf8))
        try? handle.close()
    }
}

exit(report.ok ? 0 : 1)
