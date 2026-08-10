// SPDX-License-Identifier: GPL-3.0-or-later
//
// `pane.subscribe` event `surface.changed`. `paneId` is included for
// redundancy / debugging; routing is by envelope `id` already.
//
// `sequence` is the per-pane monotonic counter the daemon assigns to
// each new surface delivery. The GUI uses it to correlate this JSON
// evt with the side-band surface payload that ships on the same XPC
// connection: the daemon sends `(JSON evt for N, surface payload
// for N)` as an atomic pair, and the GUI pairs them by `(paneId,
// sequence)`. The sequence restarts at 1 on daemon relaunch; the GUI
// keys its UI state on `paneId` so a rewound counter is harmless.
public struct SurfaceChangedEvent: Codable, Sendable, Equatable {
    public let paneId: String
    public let sequence: UInt64

    public init(paneId: String, sequence: UInt64) {
        self.paneId = paneId
        self.sequence = sequence
    }
}
