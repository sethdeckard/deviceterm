// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The GUI's reply to one published `AppCommand`.
///
/// Sent over the `app.commandResult` RPC. The daemon's
/// AppCommandCoordinator looks up the pending continuation by
/// `commandId` and resumes it with this value; the originating CLI
/// handler then returns either a JSON receipt (success / info data)
/// or a CLI-style error (mapped from the `error` payload).
///
/// The Codable payloads `data` carries for workspace verbs live in this
/// module for the same reason this type does: the GUI encodes them and the
/// CLI decodes them, so both sides must see one definition.
public struct AppCommandResult: Codable, Sendable, Equatable {
    public struct ErrorPayload: Codable, Sendable, Equatable {
        /// Stable kebab-case code. `intent.notFound`, `intent.ambiguous`,
        /// `intent.guiUnavailable`, etc.
        public let code: String
        public let message: String
        /// Optional JSON object with structured context such as a resource
        /// committed before a later step failed.
        public let details: Data?
        /// An error received from the daemon by the GUI and returned through
        /// the back-channel. The daemon relays this numeric code rather than
        /// wrapping it in the generic intent error code.
        public let rpcCode: Int?

        public init(
            code: String,
            message: String,
            details: Data? = nil,
            rpcCode: Int? = nil
        ) {
            self.code = code
            self.message = message
            self.details = details
            self.rpcCode = rpcCode
        }
    }

    /// The `commandId` from the AppCommand this is replying to.
    public let commandId: String

    /// `"ok"` for a successful side-effect with no data; `"data"`
    /// when `data` is populated (info / list verbs); `"error"`
    /// when `error` is populated. Stable strings so older readers
    /// see a recognized status.
    public let status: String

    /// JSON-encoded payload for workspace reads and mutation receipts.
    /// `nil` for side effects that return no data (status == "ok").
    public let data: Data?

    /// Typed error when `status == "error"`. Carries enough for the
    /// CLI to render a stderr line without re-classifying.
    public let error: ErrorPayload?

    public init(
        commandId: String,
        status: String,
        data: Data? = nil,
        error: ErrorPayload? = nil
    ) {
        self.commandId = commandId
        self.status = status
        self.data = data
        self.error = error
    }

    /// Convenience constructors so call sites stay readable.
    public static func ok(commandId: String) -> AppCommandResult {
        AppCommandResult(commandId: commandId, status: "ok")
    }

    public static func data(
        commandId: String,
        payload: Data
    ) -> AppCommandResult {
        AppCommandResult(
            commandId: commandId,
            status: "data",
            data: payload
        )
    }

    public static func error(
        commandId: String,
        code: String,
        message: String,
        details: Data? = nil,
        rpcCode: Int? = nil
    ) -> AppCommandResult {
        AppCommandResult(
            commandId: commandId,
            status: "error",
            error: ErrorPayload(
                code: code,
                message: message,
                details: details,
                rpcCode: rpcCode
            )
        )
    }
}
