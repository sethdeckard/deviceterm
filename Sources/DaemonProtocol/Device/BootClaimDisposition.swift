// SPDX-License-Identifier: GPL-3.0-or-later

/// What to do with a DeviceTerm-originated boot when
/// its originating terminal closes before attribution converges.
public enum BootClaimDisposition: String, Codable, Sendable, Equatable {
    case attach
    case detach
    case shutdown
}
