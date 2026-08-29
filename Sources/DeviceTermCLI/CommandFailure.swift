// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One typed CLI failure before output-mode rendering.
///
/// `details` may contain an encoded JSON object. Rendering omits invalid or
/// non-object bytes. Keeping the bytes opaque here lets each command define
/// its own additive detail shape without introducing a shared catch-all
/// value type.
struct CommandFailure: Equatable, Sendable {
    let code: CLIErrorCode
    let message: String
    let details: Data?

    init(code: CLIErrorCode, message: String, details: Data? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }

    /// Encode the public, newline-terminated failure document.
    ///
    /// Invalid or non-object detail bytes are omitted. A bad optional detail
    /// must not turn the failure itself into empty or invalid stdout.
    func jsonReceipt() -> Data {
        var error: [String: Any] = [
            "code": code.rawValue,
            "message": message
        ]
        if let details,
            let object = try? JSONSerialization.jsonObject(with: details),
            object is [String: Any] {
            error["details"] = object
        }
        let document: [String: Any] = ["error": error]
        // Strings plus a validated JSON object are always serializable. Keep
        // a literal fallback anyway: this path owns the guarantee that a
        // typed failure never produces empty stdout.
        var data = (try? JSONSerialization.data(
            withJSONObject: document,
            options: [.sortedKeys]
        )) ?? Data(#"{"error":{"code":"cli.internalError","message":"failed to encode error"}}"#.utf8)
        data.append(0x0A)
        return data
    }
}
