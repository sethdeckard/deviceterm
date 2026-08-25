// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

struct RouteFileReader: RouteFileLoading {
    // The `async` is load-bearing despite nothing being awaited inside.
    // A nonisolated `async` method runs on the global executor, so
    // declaring it this way is what moves the read and the parse off the
    // main actor; making it synchronous would run both on whichever
    // actor called it, which is always the one drawing the menu.
    // swiftlint:disable:next async_without_await
    func load(path: String) async throws -> SimulatedLocation {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw RouteFileError.unreadable(message: ErrorText.describing(error))
        }
        let document: GPXDocument
        do {
            document = try GPXDocument.parse(data)
        } catch let error as GPXParseError {
            throw RouteFileError.malformed(error)
        }
        let location = GPXRouteMapper.location(for: document)
        // Validated here rather than left to the daemon so the failure
        // arrives as a sentence about this file, next to the row the
        // user clicked, instead of as an RPC error a menu would only
        // log. The daemon still re-checks: it does not trust a client.
        if let defect = location.defect {
            throw RouteFileError.unusable(defect)
        }
        return location
    }
}
