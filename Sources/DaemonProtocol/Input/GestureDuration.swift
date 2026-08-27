// SPDX-License-Identifier: GPL-3.0-or-later

/// How long a paced gesture runs: the per-verb default when `durationMs` is
/// omitted, and the ceiling the daemon accepts.
///
/// Shared because both sides need the same numbers for different reasons. The
/// daemon substitutes a default before dispatching and rejects anything past
/// `maxMs`. The CLI needs both to size the response timeout for a verb the
/// daemon answers only once the gesture has finished: a client that guessed a
/// shorter default would give up while its own gesture was still dispatching,
/// and one that trusted an unbounded duration would wait past any deadline
/// worth having, since argv accepts integers the daemon will refuse.
public enum GestureDuration {
    /// Motion duration for `swipe` and `edge-swipe`, which share it. Long
    /// enough to read as a deliberate drag rather than a flick; the path
    /// itself is linearly interpolated, not shaped to any UIKit curve.
    public static let swipeDefaultMs: Int = 200

    /// Matches iOS's default 500ms long-press threshold.
    public static let longPressDefaultMs: Int = 500

    /// Slightly longer than swipe so the gesture reads as deliberate to
    /// UIKit's gesture recognizers.
    public static let pinchDefaultMs: Int = 300

    /// A single send of the full delta. Callers wanting a smooth scroll pass a
    /// positive `durationMs`, which sub-steps the rotation at ~60Hz.
    public static let crownDefaultMs: Int = 0

    /// Largest duration accepted for any *single* gesture phase. A `swipe`
    /// validates its start dwell, its motion, and its end dwell separately, so
    /// a legal one can run for three times this. A caller sizing a deadline
    /// has to add up every phase it sends rather than cap their total.
    ///
    /// A phase past this is refused with `invalidParams` rather than clamped,
    /// which makes it a validation bound server-side and a sanity bound on
    /// anything a client derives from a duration it has not checked.
    public static let maxMs: Int = 60_000
}
