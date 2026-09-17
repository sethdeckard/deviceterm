// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The copy for the Restart Simulator Services confirmation.
///
/// The prompt's job is to name what the restart destroys before it destroys
/// it, because this is the one recovery path in the app whose blast radius
/// reaches past deviceterm: it stops every simulator on the login, not only
/// the ones deviceterm owns. So the roster tally is in the copy rather than
/// a generic warning, and a roster that could not be read says so instead of
/// quietly reading as an empty one.
///
/// Kept separate from the alert so the wording tests without AppKit.
enum CoreSimulatorRestartDecision {
    /// What the roster read found. `unknown` is its own state rather than
    /// zeroes, because "no simulators are booted" and "deviceterm could not
    /// find out" call for opposite copy, and the read timing out is itself
    /// evidence of the wedge this prompt is offering to clear.
    struct Tally: Sendable, Equatable {
        /// The roster read did not answer, which on this path usually means
        /// CoreSimulator is already wedged.
        static let unknown = Tally()

        let booted: Int
        /// How many of `booted` deviceterm owns, which is not the same as how
        /// many it booted: a sim attached through `device.attach` is owned
        /// without deviceterm having started it.
        ///
        /// Expected not to exceed `booted`. A larger value takes the
        /// all-owned wording rather than being rejected, because the copy is
        /// what a user acts on and a disagreeing roster still has to produce a
        /// sentence.
        let owned: Int
        let isUnknown: Bool

        init(booted: Int, owned: Int) {
            self.booted = booted
            self.owned = owned
            isUnknown = false
        }

        private init() {
            booted = 0
            owned = 0
            isUnknown = true
        }
    }

    static let messageText = "Restart Simulator Services?"
    static let confirmButtonTitle = "Restart CoreSimulator"
    static let cancelButtonTitle = "Cancel"

    /// What recovers afterwards. Unlike the plain helper restart, this one
    /// stops simulators, so the panes come back as failed attachments rather
    /// than as panes whose sim is merely gone. `recoverPanes` re-attaches in
    /// place and an attach against a shut-down sim fails, so Retry re-attaches
    /// and does not boot; promising a reboot here would promise a control the
    /// slot doesn't offer.
    private static let recovery = "deviceterm's helper restarts with it. "
        + "Terminals are untouched. The simulators are gone afterwards, so "
        + "their panes can't re-attach; each shows the error in its own slot "
        + "with Retry and Close."

    /// Named unconditionally, including when the count above is zero. The
    /// count comes from `device.list`, which enumerates CoreSimulator's
    /// default device set only, while stopping the service stops every set on
    /// the login. A zero is therefore "none that deviceterm can see", and
    /// dropping the warning on it would turn a blind spot into an assurance.
    private static let loginWide = "The restart is login-wide. Every "
        + "simulator on this login stops, including ones in other device "
        + "sets, ones deviceterm never booted, and ones Xcode is debugging "
        + "into."

    static func informativeText(tally: Tally) -> String {
        [rosterSentence(tally: tally), loginWide, recovery]
            .joined(separator: " ")
    }

    /// The tally sentence. Each arm is spelled out rather than composed from
    /// a plural suffix, because the singular cases want "the one booted
    /// simulator, which…" and the plural ones want "all N…, M of them…", and
    /// a shared template that covers both ends up ungrammatical at one end.
    private static func rosterSentence(tally: Tally) -> String {
        guard !tally.isUnknown else {
            return "deviceterm could not read the simulator roster, which is "
                + "itself a sign CoreSimulator is wedged. Any booted "
                + "simulator will stop."
        }
        switch (tally.booted, tally.owned) {
        case (0, _):
            // Scoped to the set deviceterm can see, because the sentence that
            // follows says the restart reaches further than that.
            return "No simulators are booted in the default device set."

        case (1, 0):
            return "This stops the one booted simulator, which deviceterm "
                + "doesn't own."

        case (1, _):
            return "This stops the one booted simulator, which deviceterm "
                + "owns."

        case let (booted, 0):
            return "This stops all \(booted) booted simulators, none of them "
                + "owned by deviceterm."

        case let (booted, owned) where owned >= booted:
            return "This stops all \(booted) booted simulators, all of them "
                + "owned by deviceterm."

        case let (booted, owned):
            return "This stops all \(booted) booted simulators, \(owned) of "
                + "them owned by deviceterm."
        }
    }
}
