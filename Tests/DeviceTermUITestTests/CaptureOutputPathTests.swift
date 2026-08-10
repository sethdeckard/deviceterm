// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import DeviceTermUITest

/// Output-path safety for the capture verbs. These run the `--out`
/// validation, which happens *before* any ScreenCaptureKit call, so they
/// are hermetic: no GUI, no Screen Recording grant.
@Suite("capture output-path safety")
struct CaptureOutputPathTests {
    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dt-out-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("a directory --out is rejected, never deleted", arguments: ["window", "status-item"])
    func rejectsDirectoryOutput(verb: String) async throws {
        let dir = makeTempDir()
        let keep = dir.appendingPathComponent("keep.txt")
        try Data("important".utf8).write(to: keep)
        defer { try? FileManager.default.removeItem(at: dir) }

        await #expect(throws: CaptureError.self) {
            if verb == "window" {
                _ = try await CaptureService.captureWindow(bundleID: "com.deviceterm", out: dir.path)
            } else {
                _ = try await CaptureService.captureStatusItem(out: dir.path)
            }
        }
        // The directory and its contents survive: the guard refused it
        // rather than recursively removing it.
        #expect(FileManager.default.fileExists(atPath: dir.path))
        #expect(FileManager.default.fileExists(atPath: keep.path))
    }

    @Test("a special-file --out (FIFO) is rejected, never unlinked", arguments: ["window", "status-item"])
    func rejectsSpecialFileOutput(verb: String) async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fifo = dir.appendingPathComponent("pipe").path
        #expect(mkfifo(fifo, 0o644) == 0)

        await #expect(throws: CaptureError.self) {
            if verb == "window" {
                _ = try await CaptureService.captureWindow(bundleID: "com.deviceterm", out: fifo)
            } else {
                _ = try await CaptureService.captureStatusItem(out: fifo)
            }
        }
        // The FIFO survives: cleanup must never unlink a non-regular file
        // (unlinking a live socket would break its listener).
        #expect(FileManager.default.fileExists(atPath: fifo))
    }
}
