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

/// Where `HostIdentity` reads its three values from. Injectable so the resolver
/// is testable without touching this machine's sysctls or private frameworks.
protocol HostMetadataSource: Sendable {
    func model() throws -> String
    func avConferenceVersion() throws -> String
    func osBuild() throws -> String
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

/// Reads the host identity off the running system: two sysctls plus the
/// AVConference framework's bundle version.
struct SystemHostMetadata: HostMetadataSource {
    private static let avConferencePath = "/System/Library/PrivateFrameworks/AVConference.framework"

    /// A string sysctl by name, sized then read. An unreadable or empty value
    /// throws rather than substituting a placeholder: a silently blank identity
    /// would reach the wire looking like a deliberate choice.
    private static func sysctlString(_ name: String, field: HostIdentity.Field) throws -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            throw MirrorOffer.OfferError.hostIdentityUnavailable(field: field)
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            throw MirrorOffer.OfferError.hostIdentityUnavailable(field: field)
        }
        // Failable rather than lossy: a value that isn't valid UTF-8 is as
        // unusable as a missing one, and must not reach the wire as U+FFFD.
        guard let value = String(bytes: buffer.prefix { $0 != 0 }, encoding: .utf8),
            !value.isEmpty else {
            throw MirrorOffer.OfferError.hostIdentityUnavailable(field: field)
        }
        return value
    }

    func model() throws -> String { try Self.sysctlString("hw.model", field: .model) }

    func osBuild() throws -> String { try Self.sysctlString("kern.osversion", field: .osBuild) }

    func avConferenceVersion() throws -> String {
        guard let bundle = Bundle(path: Self.avConferencePath),
            let version = bundle.infoDictionary?["CFBundleVersion"] as? String,
            !version.isEmpty else {
            throw MirrorOffer.OfferError.hostIdentityUnavailable(field: .avConferenceVersion)
        }
        return version
    }
}
