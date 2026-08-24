// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Where `HostIdentity` reads its three values from. Injectable so the resolver
/// is testable without touching this machine's sysctls or private frameworks.
protocol HostMetadataSource: Sendable {
    func model() throws -> String
    func avConferenceVersion() throws -> String
    func osBuild() throws -> String
}
