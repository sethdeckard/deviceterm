// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The destination for per-window device-frame summaries: one log line when a
/// logger is supplied, plus one appended JSONL row when the configured path can
/// be opened.
///
/// Its existence is the on switch: `make` returns nil when metrics are
/// disabled, so the frame task skips every clock read rather than measuring
/// into a sink nobody reads.
///
/// One file per device, because each mirrored device builds its own sink and
/// two handles appending to one path interleave and overwrite each other's
/// rows. The device identifier lives in the filename, so rows need not repeat
/// it.
///
/// A file that cannot be opened, or a write that fails, is reported once
/// through `log` rather than swallowed: logging keeps working either way, so an
/// unreported failure looks exactly like a healthy capture until someone opens
/// the file and finds it short.
///
/// `@unchecked Sendable` is sound because the only mutable state, the file
/// handle, the encoder, and the write-failure latch, is touched exclusively on
/// the private serial `queue`; `log` is itself `@Sendable`.
final class FrameMetricsSink: @unchecked Sendable {
    private let handle: FileHandle?
    private let log: (@Sendable (String) -> Void)?
    private let queue = DispatchQueue(label: "deviceterm.frame-metrics")
    private let encoder = JSONEncoder()
    private var reportedWriteFailure = false

    init(path: String?, log: (@Sendable (String) -> Void)?) {
        self.log = log
        guard let path else {
            handle = nil
            return
        }
        let expanded = (path as NSString).expandingTildeInPath
        if !FileManager.default.fileExists(atPath: expanded) {
            FileManager.default.createFile(atPath: expanded, contents: nil)
        }
        let opened = FileHandle(forWritingAtPath: expanded)
        opened?.seekToEndOfFile()
        handle = opened
        if opened == nil {
            log?("frame-metrics: can't open \(expanded); logging only, no JSONL rows")
        }
    }

    /// Build a sink when `baseDirectory` names one, nil (metrics off)
    /// otherwise. `deviceId` keys the file so concurrent device panes never
    /// share one.
    static func make(
        baseDirectory: String?,
        deviceId: String,
        log: (@Sendable (String) -> Void)?
    ) -> FrameMetricsSink? {
        guard let base = baseDirectory, !base.isEmpty else { return nil }
        return FrameMetricsSink(path: "\(base).\(deviceId).frames.jsonl", log: log)
    }

    func record(_ summary: DeviceFrameMetricsSummary) {
        log?(summary.logLine)
        guard let handle else { return }
        queue.async { [self] in
            guard var data = try? encoder.encode(summary) else {
                reportWriteFailure("the summary would not encode")
                return
            }
            data.append(0x0A)
            do {
                try handle.write(contentsOf: data)
            } catch {
                reportWriteFailure(String(describing: error))
            }
        }
    }

    /// Flush pending writes (tests read the file right after recording).
    func drain() {
        queue.sync {}
    }

    /// Report the first write failure and suppress later failure messages, so
    /// a broken capture doesn't also flood the log. Later writes are still
    /// attempted, so a transient failure can recover on its own.
    /// `queue`-confined, like the handle it speaks for.
    private func reportWriteFailure(_ reason: String) {
        guard !reportedWriteFailure else { return }
        reportedWriteFailure = true
        log?("frame-metrics: JSONL write failed (\(reason)); at least one row was lost,"
            + " and further failures will not be logged")
    }
}
