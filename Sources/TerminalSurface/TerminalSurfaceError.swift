// SPDX-License-Identifier: GPL-3.0-or-later
//
// TerminalSurfaceError: the failures a TerminalSurface can throw.
// `attach` raises the surface-creation and re-attach cases; the
// input and capture verbs raise the not-yet-attached and
// capture-refused ones.
//
// Kept tiny and libghostty-free on purpose: the protocol lives in a
// module `App` can depend on without the C framework, so its error
// type can't reference `ghostty_*` codes. The libghostty bridge maps
// its own failure detail onto these cases.

import Foundation

public enum TerminalSurfaceError: Error, Sendable, Equatable {
    /// The underlying engine could not create a surface (e.g.
    /// libghostty's `ghostty_surface_new` returned NULL). Usually a
    /// resource-bundle or GPU-init problem, not a caller mistake.
    case surfaceCreationFailed(
        detail:
        String
        )

    /// `attach` was called on a surface that is already attached.
    /// Surfaces are single-shot: make a new one to re-run a shell.
    case alreadyAttached

    /// An operation requiring an attached surface (e.g. `sendInput`)
    /// was called before `attach` succeeded: viewDidLoad hasn't
    /// run yet on the hosting VC, or attach itself failed. The
    /// orchestrator-only `deviceterm tab send-input` verb surfaces
    /// this as the typed failure rather than silently dropping the
    /// bytes; the caller can either activate the tab first
    /// (forcing view load) or treat the attach failure as fatal.
    case notAttached

    /// The engine refused a screen-text read (`readScreenText`).
    /// Usually transient; typically means the surface is
    /// mid-resize or libghostty's text-extraction path returned
    /// false. The orchestrator-only `deviceterm tab capture` verb
    /// relays this so the caller can retry.
    case captureFailed(
        detail:
        String
        )
}
