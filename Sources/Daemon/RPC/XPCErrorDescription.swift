// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@preconcurrency import XPC

/// Name an `XPC_TYPE_ERROR` object for a log line.
///
/// A connection teardown is only diagnostic if the timeline says which error
/// caused it. Naming the error distinguishes an interrupted connection from an
/// invalidated one before teardown discards the state that would explain it.
///
/// libxpc vends its errors as singleton dictionaries, so identity comparison is
/// the documented way to classify them; `XPC_ERROR_KEY_DESCRIPTION` carries the
/// human string for anything outside the known set.
enum XPCErrorDescription {
    /// A short, log-safe name for an XPC error object.
    ///
    /// The three named cases are the ones that actually reach a connection
    /// handler in this daemon; everything else falls back to libxpc's own
    /// description so an unexpected error is still legible rather than being
    /// flattened to "unknown". Never carries caller data, so it is `.public`
    /// at every call site.
    static func of(_ event: xpc_object_t) -> String {
        if event === XPC_ERROR_CONNECTION_INTERRUPTED {
            return "connection-interrupted"
        }
        if event === XPC_ERROR_CONNECTION_INVALID {
            return "connection-invalid"
        }
        if event === XPC_ERROR_TERMINATION_IMMINENT {
            return "termination-imminent"
        }
        guard let raw = xpc_dictionary_get_string(event, XPC_ERROR_KEY_DESCRIPTION) else {
            return "unknown-xpc-error"
        }
        return String(cString: raw)
    }
}
