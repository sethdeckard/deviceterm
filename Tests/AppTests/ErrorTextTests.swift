// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Foundation
import Testing

// ErrorTextTests: an error's own words survive to the user.
//
// `localizedDescription` is the trap this exists to avoid. It returns
// something useful only for `LocalizedError` and `CustomNSError`; for any
// other Swift error Foundation substitutes "The operation couldn't be
// completed. (App.DaemonClientError error 0.)" and the type's real
// content is gone. `DaemonClientError` is precisely that shape, so every
// daemon code and message would be replaced by that placeholder.

private struct FriendlyError: LocalizedError {
    var errorDescription: String? { "The device is not connected." }
}

/// The other way a type can supply a real `localizedDescription`.
private struct UserInfoError: CustomNSError {
    static var errorDomain: String { "com.deviceterm.tests" }
    var errorCode: Int { 42 }
    var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: "The tunnel closed."] }
}

private struct SilentUserInfoError: CustomNSError {
    static var errorDomain: String { "com.deviceterm.tests" }
    var errorCode: Int { 7 }
}

private struct BlankUserInfoError: CustomNSError {
    static var errorDomain: String { "com.deviceterm.tests" }
    var errorCode: Int { 8 }
    var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: ""] }
}

/// Conforms to both, to pin which one wins.
private struct DoublyDescribedError: LocalizedError, CustomNSError {
    static var errorDomain: String { "com.deviceterm.tests" }
    var errorDescription: String? { "from LocalizedError" }
    var errorCode: Int { 1 }
    var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: "from CustomNSError"] }
}

/// A `LocalizedError` with nothing to say must not shrink the output to
/// an empty string, which would render as a blank alert body.
private struct BlankLocalizedError: LocalizedError {
    var errorDescription: String? { "" }
}

/// `DaemonClientError` is `CustomStringConvertible`, not
/// `LocalizedError`, so its code and message reach the user only through
/// interpolation.
@Test("a daemon error keeps its code and message")
func daemonErrorKeepsItsDetail() {
    let text = ErrorText.describing(DaemonClientError.daemon(code: -32_000, message: "device busy"))
    #expect(text.contains("device busy"))
    #expect(text.contains("32000") || text.contains("32_000"))
    #expect(!text.contains("operation couldn"), "Foundation's placeholder replaced the real message")
}

@Test("a localized error uses its own description")
func localizedErrorIsPreferred() {
    #expect(ErrorText.describing(FriendlyError()) == "The device is not connected.")
}

@Test("an empty localized description falls through")
func emptyLocalizedDescriptionFallsThrough() {
    #expect(!ErrorText.describing(BlankLocalizedError()).isEmpty)
}

/// The second way a type supplies a real `localizedDescription`, and the
/// one a `LocalizedError`-only check silently drops: interpolating a
/// `CustomNSError` yields its bare type name, so the message vanishes.
@Test("a CustomNSError keeps its message")
func customNSErrorKeepsItsMessage() {
    #expect(ErrorText.describing(UserInfoError()) == "The tunnel closed.")
}

/// Both ways of supplying no message, an absent key and a blank value,
/// must fall through without producing Foundation's placeholder or an
/// empty alert body.
@Test("a CustomNSError with no message falls through", arguments: [
    SilentUserInfoError() as any Error,
    BlankUserInfoError()
])
func customNSErrorWithoutAMessageFallsThrough(error: any Error) {
    let text = ErrorText.describing(error)
    #expect(!text.isEmpty)
    #expect(!text.contains("operation couldn"))
}

/// Foundation resolves a type conforming to both in favour of the
/// `CustomNSError` key. Matching that keeps this helper from disagreeing
/// with `localizedDescription` wherever the latter means something.
@Test("both conformances resolve the way Foundation does")
func bothConformancesMatchFoundation() {
    let error = DoublyDescribedError()
    #expect(ErrorText.describing(error) == error.localizedDescription)
    #expect(ErrorText.describing(error) == "from CustomNSError")
}
