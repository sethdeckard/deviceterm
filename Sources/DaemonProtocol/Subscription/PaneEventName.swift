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
    /// The device rotated. Broadcast on every `pane.input.rotate` so a
    /// rotation triggered from outside the owning GUI (e.g. `deviceterm
    /// rotate`) reaches the GUI, which re-renders and re-maps input to
    /// the new orientation instead of drifting from the device.
    case orientationChanged = "orientation.changed"
}
