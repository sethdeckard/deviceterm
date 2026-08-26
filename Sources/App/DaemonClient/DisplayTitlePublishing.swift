// SPDX-License-Identifier: GPL-3.0-or-later

/// Narrow GUI role for publishing a tab's normalized label under its primary
/// terminal's session. One of the role protocols carved out of `DaemonClient`
/// so a consumer (and its test fake) depends only on the surface it uses.
///
/// `@MainActor`/`AnyObject` because the whole GUI daemon path is main-actor and
/// reference-typed.
@MainActor
protocol DisplayTitlePublishing: AnyObject {
    /// `session.setDisplayTitle`: `.validatedGUI`-scoped, so no cap rides on
    /// the wire (the GUI's audit token is the authority). Pushed under the
    /// tab's PRIMARY terminal session; the other terminals of a split tab
    /// carry no title. A nil `title` is the **clear**, not a no-op: the
    /// conforming client normalizes before encoding, and a title that
    /// normalizes to nothing still has to replace the cached one.
    func setDisplayTitle(sessionId: String, title: String?) async throws
}
