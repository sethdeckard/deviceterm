// SPDX-License-Identifier: GPL-3.0-or-later

/// What a mirror run has managed to do so far, and what that makes a give-up
/// mean.
///
/// A run gives up the same way whichever thing went wrong: sessions that
/// produce no frames until the restart budget runs out. An unplugged device
/// can't open a session; neither can one whose encoder refuses. Whether this
/// run ever mirrored is the only thing on hand that tells a give-up worth
/// retrying from one that isn't, so it is the one thing worth remembering
/// across restarts.
///
/// Split out from the receive loop because it is the whole basis of the
/// disconnect-versus-failure call, and the loop it lives in can't be driven
/// without a device.
struct MirrorRunHistory {
    /// Whether any session in this run decoded a frame. Latches: a run that
    /// mirrored and then went quiet is still a run that mirrored, which is
    /// exactly the case a disconnect has to be recognized from.
    private(set) var everProduced = false

    /// Which terminal state giving up now lands in. A run that mirrored and
    /// then stopped is worth retrying, since whatever it needs has worked
    /// here before; one that never mirrored would land in the same place.
    var giveUpTermination: FeedTermination {
        everProduced ? .disconnected : .failed
    }

    /// Fold in one finished session's frame count.
    mutating func record(framesProduced: Int) {
        if framesProduced > 0 { everProduced = true }
    }
}
