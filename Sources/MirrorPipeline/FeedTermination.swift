// SPDX-License-Identifier: GPL-3.0-or-later

/// Why a `DecodedFrameFeed`'s stream ended.
///
/// The end of the stream alone doesn't say, and the three cases want opposite
/// handling: a consumer should re-mirror after a disconnect, surface an error
/// after a failure, and do nothing at all after a stop it asked for. Getting
/// that wrong is expensive in both directions. Treating a failure as a
/// disconnect re-attaches straight back into it; treating a disconnect as a
/// failure strands a pane the device would happily come back to.
package enum FeedTermination: Equatable, Sendable {
    /// Still streaming, or never started.
    case active
    /// A caller asked: `stop()`, or the consumer abandoned the stream.
    case stopped
    /// The stream stopped after this run had mirrored at least once, and
    /// didn't come back within the feed's restart budget. **Retryable**, which
    /// is a judgement about what to do rather than a diagnosis: the usual
    /// cause is the device leaving (unplugged, locked, tunnel dropped), but a
    /// mirror that broke partway through a working run reaches this too, and
    /// nothing here separates them. A consumer that retries should expect to
    /// arrive back here when it was the latter.
    case disconnected
    /// The run never mirrored at all before its restart budget ran out, so
    /// re-attaching would land in the same place. Not retryable: a consumer
    /// should surface it.
    case failed
}
