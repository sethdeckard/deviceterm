// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The most informative text an error can give a user.
///
/// `localizedDescription` is the trap this exists to avoid. It says
/// something real only when the type supplies it, through
/// `CustomNSError`'s `NSLocalizedDescriptionKey` or through
/// `LocalizedError.errorDescription`. For anything else Foundation
/// substitutes a placeholder, "The operation couldn't be completed.
/// (App.DaemonClientError error 0.)", and whatever the type knew is gone.
/// `DaemonClientError` is exactly that shape: it conforms to
/// `CustomStringConvertible` and carries the daemon's own code and
/// message, both of which `localizedDescription` discards.
///
/// So the two supplied forms are read directly and everything else
/// interpolates. Foundation prefers the `CustomNSError` key over
/// `LocalizedError.errorDescription` for a type supplying both, and this
/// uses the same order, so it cannot quietly disagree with
/// `localizedDescription` wherever that means something.
///
/// A bridged system error (`CocoaError`, `CLError`) matches neither arm,
/// because its message lives on the underlying `NSError` rather than in
/// `errorUserInfo`. Interpolation still carries it, in the verbose
/// `Error Domain=… Code=… "…"` form: worse to read, but nothing lost.
/// `as? NSError` is not the fix for that, since the cast succeeds for
/// *every* Swift error and would route them all back through
/// `localizedDescription`, discarding whatever only interpolation
/// carries.
///
/// The attach placeholder and the Use My Location alert both report
/// daemon failures through this helper.
enum ErrorText {
    /// The best text `error` can offer: whichever description it
    /// actually supplies, otherwise its `description`, which is what
    /// carries a daemon code and message.
    static func describing(_ error: any Error) -> String {
        let userInfoDescription = (error as? any CustomNSError)?
            .errorUserInfo[NSLocalizedDescriptionKey] as? String
        if let userInfoDescription, !userInfoDescription.isEmpty {
            return userInfoDescription
        }
        if let described = (error as? any LocalizedError)?.errorDescription,
            !described.isEmpty {
            return described
        }
        return "\(error)"
    }
}
