// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

private let snapshotLog = Logger(subsystem: "com.deviceterm", category: "pane-snapshot")

/// Answers pane snapshot requests dropped into the dev seat's
/// `snapshots/requests` directory. Started only in the seat's own debug
/// build (`DevSeatDecision`).
///
/// A request is `<id>.json` (`PaneSnapshotRequest`), which the watcher takes
/// by deleting it, so each one runs once. It answers with `<id>.done.json`
/// beside it (`PaneSnapshotOutcome`). Writers rename a finished file into
/// place, so a request is never read half written; files that don't end in
/// `.json` are left alone.
///
/// The seat is checked again for every request: once another checkout has
/// been blessed, this app refuses new requests without capturing anything.
/// With no watcher running at all, a request goes unanswered.
@MainActor
final class PaneSnapshotWatcher {
    /// Runs one request against a pane, reporting through the closure it's
    /// handed, from any thread.
    typealias Handler = @MainActor (
        PaneSnapshotRequest,
        @escaping @Sendable (PaneSnapshotOutcome) -> Void
    ) -> Void

    private let requests: String
    private let stillSeat: @MainActor () -> Bool
    private let handler: Handler
    private var source: DispatchSourceFileSystemObject?

    init(seatDirectory: String, stillSeat: @escaping @MainActor () -> Bool, handler: @escaping Handler) {
        requests = (seatDirectory as NSString).appendingPathComponent("snapshots/requests")
        self.stillSeat = stillSeat
        self.handler = handler
    }

    /// Write `<id>.done.json` into `directory`, whole, from any thread.
    nonisolated private static func answering(
        id: String,
        in directory: String
    ) -> @Sendable (PaneSnapshotOutcome) -> Void {
        { outcome in
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(id).done.json")
            do {
                try JSONEncoder().encode(outcome).write(to: url, options: .atomic)
            } catch {
                snapshotLog.error("snapshot \(id, privacy: .public): could not answer: \(error, privacy: .public)")
            }
        }
    }

    /// Create the requests directory, watch it, and answer whatever is
    /// already waiting.
    func start() throws {
        try FileManager.default.createDirectory(
            atPath: requests,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let descriptor = open(requests, O_EVTONLY)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: .write,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scan() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
        snapshotLog.notice("answering pane snapshot requests in \(self.requests, privacy: .public)")
        scan()
    }

    private func scan() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: requests)) ?? []
        for name in names.sorted() where name.hasSuffix(".json") && !name.hasSuffix(".done.json") {
            take(name)
        }
    }

    private func take(_ name: String) {
        let path = (requests as NSString).appendingPathComponent(name)
        let id = String(name.dropLast(".json".count))
        let data = FileManager.default.contents(atPath: path)
        // Taken by removing it, so the event the answer raises can't run it
        // again.
        guard (try? FileManager.default.removeItem(atPath: path)) != nil else { return }
        let answer = Self.answering(id: id, in: requests)
        guard stillSeat() else {
            answer(.refused("this app no longer holds the dev seat"))
            return
        }
        guard let data, let request = try? JSONDecoder().decode(PaneSnapshotRequest.self, from: data) else {
            answer(.refused("not a snapshot request: expected udid, seconds, and out"))
            return
        }
        if let problem = request.problem {
            answer(.refused(problem))
            return
        }
        snapshotLog.notice(
            "snapshot \(id, privacy: .public): \(request.udid, privacy: .public) for \(request.seconds)s"
        )
        handler(request, answer)
    }
}
