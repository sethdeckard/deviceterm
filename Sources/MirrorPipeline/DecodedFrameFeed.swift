// SPDX-License-Identifier: GPL-3.0-or-later
/// A single-use source of decoded mirror frames.
///
/// `frames(onFatal:)` starts the pipeline and returns the frame stream; the
/// fatal callback fires at most once, only if the pipeline gives up for good
/// (never on a voluntary `stop`). Both terminal signals, a finished stream and
/// the fatal callback, are the pipeline's; transient hiccups are handled
/// internally and don't surface here. Calling `frames` a second time, or after
/// the feed reaches any terminal state, returns an already-finished stream
/// without re-arming the callback.
package protocol DecodedFrameFeed: Sendable {
    /// Why the stream ended, for a consumer that has observed the end.
    ///
    /// A consumer can't tell the cases apart from the end of the stream
    /// alone, and it can't wait for `onFatal` either: a conformer may finish
    /// the stream before reporting, so the consumer can observe the end
    /// first. **A conformer must therefore settle this before it finishes the
    /// stream**, so a consumer that has seen the end can trust it.
    var termination: FeedTermination { get }

    /// Begin decoding and yield frames. `onFatal` is supplied at start (not a
    /// settable property, since a mutable callback on a `Sendable` type would be a
    /// data race) and is invoked at most once with a reason if the pipeline
    /// fails terminally.
    func frames(onFatal: @escaping @Sendable (String) -> Void) -> AsyncStream<DecodedFrame>

    /// Stop decoding. Synchronous and idempotent: it guarantees no *new* frame is
    /// yielded after it returns and that the stream finishes; it does not claim
    /// to interrupt a decode callback already in flight (that late frame is
    /// dropped).
    func stop()
}
