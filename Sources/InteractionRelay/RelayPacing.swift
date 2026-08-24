// SPDX-License-Identifier: GPL-3.0-or-later
//
// RelayPacing: the clock the scripted App Switcher trajectory paces against.
//
// Sleeping a nominal interval per frame and treating it as the time spent lets
// each frame's scheduler leeway compound, so a trajectory drifts longer the
// more frames it plays. Frames are instead due at absolute offsets from one
// anchor, which bounds the total error against that anchor.
//
// This mirrors the daemon's gesture pacer rather than sharing it: the relay
// sits below `Daemon` in the dependency graph and cannot import it, and pushing
// the math down into `ChannelBootstrap` would put gesture timing inside a
// transport module. The trajectory also wants a plain fixed cadence rather than
// the daemon's clamp-and-divide, so the duplicated part is small.

import Foundation

/// The clock and sleeper the App Switcher trajectory schedules against.
protocol RelayPacing: Sendable {
    func now() -> ContinuousClock.Instant
    /// Suspend until `deadline`. Non-throwing, and returns early when the task
    /// is cancelled, so a cancelled trajectory still reaches its release
    /// attempt rather than abandoning the contact mid-swipe.
    func sleep(until deadline: ContinuousClock.Instant) async
}
