// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The identity deviceterm presents to a device as the offering endpoint.
/// The values are read from the running system when an offer is built.
struct HostIdentity: Sendable, Equatable {
    /// Which field of the identity a resolution failure refers to.
    enum Field: String, Sendable, Equatable {
        case model
        case avConferenceVersion
        case osBuild
    }

    /// Hardware model identifier (`hw.model`).
    let model: String
    /// AVConference framework `CFBundleVersion`.
    let avConferenceVersion: String
    /// OS build (`kern.osversion`).
    let osBuild: String
}

extension HostIdentity {
    /// Resolve each identity value from the source, propagating the first error.
    static func resolve(using source: some HostMetadataSource) throws -> HostIdentity {
        HostIdentity(
            model: try source.model(),
            avConferenceVersion: try source.avConferenceVersion(),
            osBuild: try source.osBuild()
        )
    }

    /// This machine's identity.
    static func current() throws -> HostIdentity {
        try resolve(using: SystemHostMetadata())
    }
}
