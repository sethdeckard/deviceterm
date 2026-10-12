// SPDX-License-Identifier: GPL-3.0-or-later

/// `pane.subscribe` event `input.changed`. Says whether the pane's input is
/// reaching its device. Replayed to new subscribers only when the state is not
/// `ok`; subscribers start from `ok`.
///
/// Published when the state changes. A backend without transport stalls can
/// report `ok` or `recovering`.
public struct InputChangedEvent: Codable, Sendable, Equatable {
    public let paneId: String
    /// An unknown value from a newer daemon decodes as a failure, which the
    /// GUI drops like any event it can't read.
    public let state: InputHealth

    public init(paneId: String, state: InputHealth) {
        self.paneId = paneId
        self.state = state
    }
}
