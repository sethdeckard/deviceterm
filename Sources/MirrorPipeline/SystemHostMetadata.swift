// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

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
