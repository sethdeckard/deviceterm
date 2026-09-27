// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// Pairs each frame's JSON `surface.changed` notice with its side-band surface.
///
/// The two halves travel as separate messages and are thinned independently
/// on the daemon: the JSON channel folds an unread notice into a newer one,
/// and the leased delivery worker replaces a queued frame it has not started.
/// Either can leave one half of a frame with no partner, and a subscribe
/// replay can reach the GUI after a newer live frame.
///
/// Delivery is latest-only, so once a frame yields, no older frame for the same
/// subscription can be shown. Yielding a sequence therefore drops every older
/// parked half for that subscription, and a half that arrives at or below it is
/// dropped on arrival. A dropped side-band releases its lease by ARC at once,
/// rather than holding back the cumulative release watermark (and with it
/// every newer generation's daemon slot) until the sweep. A dropped JSON half
/// is never yielded, so it cannot replace a newer frame the consumer has not
/// pulled yet.
struct SurfacePairTable {
    /// Correlation key for one delivered frame. The subscription token
    /// disambiguates two subscriptions on one pane that carry the same
    /// `(paneId, sequence)`, so their frames never cross-deliver.
    struct Key: Hashable {
        let paneId: String
        let sequence: UInt64
        let token: UUID
    }

    /// A frame ready for its subscription. `lease` is nil for a JSON half the
    /// sweep timed out, so the view keeps its last good frame.
    struct Resolved {
        let token: UUID
        let event: SurfaceChangedEvent
        let lease: SurfaceLease?
    }

    /// One subscription's frame stream: sequences only ever advance within it.
    private struct Stream: Hashable {
        let paneId: String
        let token: UUID
    }

    /// One half of a slot. The `lease` is built when the side-band lands; for
    /// a leased frame that means its use-count bump and accountant `acquire`
    /// happen immediately (even before the JSON half or the subscribe
    /// response), while an unleased frame takes neither. A dropped slot
    /// releases the lease by ARC.
    private struct Slot {
        var event: SurfaceChangedEvent?
        var lease: SurfaceLease?
        var insertedAt: Date
    }

    private var slots: [Key: Slot] = [:]
    /// The newest sequence yielded per subscription.
    private var yielded: [Stream: UInt64] = [:]

    var count: Int { slots.count }
    var isEmpty: Bool { slots.isEmpty }

    /// Park one half, or complete its slot. Returns the frame to yield when
    /// both halves are present, and nil when the half parks or is dropped
    /// because a frame at the same or a newer sequence has already yielded for
    /// its subscription.
    mutating func offer(
        _ key: Key,
        now: Date,
        event: SurfaceChangedEvent? = nil,
        lease: SurfaceLease? = nil
    ) -> Resolved? {
        let stream = Stream(paneId: key.paneId, token: key.token)
        if let newest = yielded[stream], key.sequence <= newest { return nil }
        var slot = slots[key] ?? Slot(event: nil, lease: nil, insertedAt: now)
        if let event { slot.event = event }
        if let lease { slot.lease = lease }
        guard let completeEvent = slot.event, let completeLease = slot.lease else {
            slots[key] = slot
            return nil
        }
        slots.removeValue(forKey: key)
        markYielded(stream, through: key.sequence)
        return Resolved(token: key.token, event: completeEvent, lease: completeLease)
    }

    /// Drop every half parked for at least `maxAge`. A side-band-only half is
    /// dropped and its lease released by ARC. The newest expired JSON-only
    /// half per subscription comes back with a nil lease and counts as that
    /// subscription's yield, so older halves go with it.
    mutating func sweep(now: Date, maxAge: TimeInterval) -> [Resolved] {
        var expired: [Stream: (key: Key, event: SurfaceChangedEvent)] = [:]
        for (key, slot) in slots where now.timeIntervalSince(slot.insertedAt) >= maxAge {
            slots.removeValue(forKey: key)
            guard let event = slot.event else { continue }
            let stream = Stream(paneId: key.paneId, token: key.token)
            if let kept = expired[stream], kept.key.sequence > key.sequence { continue }
            expired[stream] = (key, event)
        }
        return expired.map { stream, newest in
            markYielded(stream, through: newest.key.sequence)
            return Resolved(token: newest.key.token, event: newest.event, lease: nil)
        }
    }

    /// Forget a subscription that ended, so the table doesn't grow with every
    /// resubscribe over a long session.
    mutating func forget(token: UUID) {
        slots = slots.filter { key, _ in key.token != token }
        yielded = yielded.filter { stream, _ in stream.token != token }
    }

    mutating func removeAll() {
        slots.removeAll()
        yielded.removeAll()
    }

    /// Record `sequence` as the stream's newest yield and drop every half
    /// parked at or below it.
    private mutating func markYielded(_ stream: Stream, through sequence: UInt64) {
        yielded[stream] = max(yielded[stream] ?? 0, sequence)
        slots = slots.filter { key, _ in
            key.paneId != stream.paneId || key.token != stream.token || key.sequence > sequence
        }
    }
}
