// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import DeviceTermUITest

@Suite("target ownership across processes and windows")
struct TargetOwnersTests {
    /// The case window ownership alone misses: a second instance that
    /// shows nothing owns no window to be counted, and the caller may have
    /// meant either it or the visible one.
    @Test
    func countsALiveProcessThatOwnsNoWindow() {
        let owners = TargetOwners.combined(processes: [100, 200], windowOwners: [100])
        #expect(owners == [100, 200])
    }

    @Test
    func oneProcessOwningSeveralWindowsIsOneOwner() {
        #expect(TargetOwners.combined(processes: [100], windowOwners: [100]) == [100])
    }

    /// A window owner absent from the process list still owns pixels a
    /// capture would return, so it counts.
    @Test
    func countsAWindowOwnerMissingFromTheProcessList() {
        #expect(TargetOwners.combined(processes: [100], windowOwners: [200]) == [100, 200])
    }

    @Test
    func isEmptyWhenNothingIsRunningAndNoWindowIsOwned() {
        #expect(TargetOwners.combined(processes: [], windowOwners: []).isEmpty)
    }

    /// A single live process with no windows still produces one combined
    /// owner.
    @Test
    func oneProcessWithNoWindowsIsASingleOwner() {
        #expect(TargetOwners.combined(processes: [100], windowOwners: []) == [100])
    }
}
