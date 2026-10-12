// SPDX-License-Identifier: GPL-3.0-or-later

/// Whether a pane's input is reaching its device, as `input.changed` reports
/// it. The rawValues are the wire contract.
public enum InputHealth: String, Codable, Sendable, Equatable {
    /// Nothing is refusing input.
    case ok
    /// The simulator's HID transport is refusing input: an earlier send hasn't
    /// completed. It clears once the client's sends drain.
    case stalled
    /// The pane's contact lane is refusing new contact while it releases one
    /// that may still be down. The transport itself is taking input.
    case recovering
}
