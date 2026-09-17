// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Testing

/// What the Restart Simulator Services prompt tells the user it is about to
/// destroy.
///
/// The copy is the safety mechanism on this path. It is the only thing between
/// a menu item and every simulator on the login, so the tests are about the
/// claims it makes: that it never understates the count, that it says so when
/// it doesn't know the count rather than implying zero, and that it stays
/// grammatical at the boundaries where a shared plural template would not.
struct CoreSimulatorRestartDecisionTests {
    private func text(booted: Int, owned: Int) -> String {
        CoreSimulatorRestartDecision.informativeText(
            tally: CoreSimulatorRestartDecision.Tally(booted: booted, owned: owned)
        )
    }

    /// The count is the number that matters, so every arm has to state it.
    @Test(arguments: [(2, 1), (3, 0), (5, 5), (11, 4)])
    func thePluralCopyNamesTheBootedCount(booted: Int, owned: Int) {
        #expect(text(booted: booted, owned: owned).contains("all \(booted) booted simulators"))
    }

    /// Singular gets its own phrasing rather than "all 1 booted simulators",
    /// which is what a shared template would produce.
    @Test(arguments: [0, 1])
    func oneBootedSimulatorReadsAsOne(owned: Int) {
        let text = text(booted: 1, owned: owned)
        #expect(text.contains("the one booted simulator"))
        #expect(!text.contains("all 1"))
        #expect(!text.contains("simulators,"))
    }

    /// Attribution is a separate claim from the count, and the three shapes
    /// read differently enough that each is spelled out.
    ///
    /// The claim is ownership, never authorship. A sim attached through
    /// `device.attach` is owned by deviceterm without having been booted by
    /// it, so copy saying "booted by deviceterm" would misattribute every
    /// attached sim in the roster.
    @Test
    func attributionIsNamedSeparatelyFromTheCount() {
        #expect(text(booted: 1, owned: 1).contains("which deviceterm owns"))
        #expect(text(booted: 1, owned: 0).contains("which deviceterm doesn't own"))
        #expect(text(booted: 3, owned: 0).contains("none of them owned by deviceterm"))
        #expect(text(booted: 3, owned: 3).contains("all of them owned by deviceterm"))
        #expect(text(booted: 3, owned: 1).contains("1 of them owned by deviceterm"))
    }

    /// No arm may claim deviceterm booted anything, since ownership and
    /// authorship diverge for an attached sim.
    @Test(arguments: [(0, 0), (1, 0), (1, 1), (3, 0), (3, 1), (3, 3)])
    func noArmClaimsDevicetermBootedTheSimulators(booted: Int, owned: Int) {
        #expect(!text(booted: booted, owned: owned).contains("booted by deviceterm"))
    }

    /// An empty roster still warns. `device.list` enumerates CoreSimulator's
    /// default device set only, while stopping the service stops every set on
    /// the login, so a zero means "none deviceterm can see" rather than "none
    /// running". Dropping the warning here would turn that blind spot into an
    /// assurance, and a sim booted under `simctl --set` would die unmentioned.
    @Test
    func anEmptyRosterStillWarnsAndSaysWhichSetItCounted() {
        let text = text(booted: 0, owned: 0)
        #expect(text.contains("No simulators are booted in the default device set"))
        #expect(text.contains("login-wide"))
        #expect(text.contains("other device sets"))
    }

    /// The copy must not promise a control the failed-attach slot doesn't
    /// offer. `recoverPanes` re-attaches in place, an attach against a
    /// stopped sim fails, and that slot's Retry re-attaches rather than boots.
    @Test(arguments: [(0, 0), (1, 1), (4, 2)])
    func theRecoveryCopyPromisesRetryRatherThanReboot(booted: Int, owned: Int) {
        let text = text(booted: booted, owned: owned)
        #expect(text.contains("Retry and Close"))
        #expect(!text.lowercased().contains("reboot"))
        #expect(!text.lowercased().contains("shutdown overlay"))
    }

    /// The failure this exists to prevent: a roster read that timed out
    /// rendering as "nothing will be lost". The read failing is evidence of
    /// the wedge, so it has to read as uncertainty, and the warning stays.
    @Test
    func anUnknownRosterNeverReadsAsAnEmptyOne() {
        let text = CoreSimulatorRestartDecision.informativeText(tally: .unknown)
        #expect(text.contains("could not read the simulator roster"))
        #expect(!text.contains("No simulators are booted"))
        #expect(text.contains("login-wide"))
    }

    /// Every roster warns about the login-wide reach, whatever the count and
    /// whoever owns them, including a roster deviceterm owns all of.
    @Test(arguments: [(1, 0), (1, 1), (4, 0), (4, 4)])
    func anyBootedSimulatorWarnsAboutTheLoginWideReach(booted: Int, owned: Int) {
        #expect(text(booted: booted, owned: owned).contains("login-wide"))
    }

    /// Ownership can't exceed the booted count, but the copy is what a user
    /// acts on, so a roster that disagrees with itself still has to produce a
    /// sentence rather than a crash or a negative remainder.
    @Test
    func anImpossibleTallyStillReadsSensibly() {
        #expect(text(booted: 2, owned: 9).contains("all of them owned by deviceterm"))
    }
}
