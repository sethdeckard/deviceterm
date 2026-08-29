// SPDX-License-Identifier: GPL-3.0-or-later

/// The method names of the events streamed over a
/// `pane.subscribe` subscription. Shared single source of truth so the
/// daemon's producer and the GUI client's consumer can't drift to two
/// different literals. Like RPCMethod, the rawValues ARE the wire
/// contract (bump `wireVersion` to change one). Mirrors the
/// `RPCEnvelope.MessageType` string-enum pattern.
public enum PaneEventName: String, Sendable, Equatable, CaseIterable {
    case surfaceChanged = "surface.changed"
    case stateChanged = "state.changed"
    /// The pane's confirmed presentation orientation changed. Simulator
    /// display observation and physical-device rotation replies both publish
    /// through this event.
    case orientationChanged = "orientation.changed"
}
