// SPDX-License-Identifier: GPL-3.0-or-later
//
// PeerIdentity: self-mirror peer validation for the
// automation-mint + automation-scope gate on XPC peers.
//
// At daemon startup the daemon reads its own signing info via
// `SecCodeCopySelf` → `SecCodeCopyStaticCode` →
// `SecCodeCopySigningInformation` and caches the result in
// `selfIdentity`. When an XPC peer asks for an
// automation-scoped operation (or mints an automation
// session), the validator runs the same chain on the peer's
// audit-token-derived `SecCode` and compares the result against
// the daemon's own signature:
//
//   - Production (Developer-ID self): peer team identifier must
//     match daemon team identifier AND peer bundle id must match
//     the expected host bundle id (daemon bundle id with the
//     trailing `.daemon` stripped) AND peer is Developer-ID-
//     signed.
//   - Ad-hoc edge-case branch (ad-hoc self): peer must be
//     ad-hoc-signed with the matching bundle id AND its process
//     path must resolve to a sibling of the daemon's process
//     directory. Only reached when both binaries are ad-hoc
//     signed in the same build tree (the hermetic
//     `BundleCodesignTests --ephemeral` path).
//   - Mixed (Developer-ID self + ad-hoc peer, or vice versa) →
//     rejected. Catches an attacker who ad-hoc-signs a binary
//     claiming the host bundle id.
//
// Open-source friendly: no team identifier or designated
// requirement is committed to source. The validator reads the
// daemon's own signature and the peer's signature, then matches.
// Forks rebrand by changing the bundle id; the validator picks
// up the new team automatically.

import DaemonProtocol
import Foundation
import Security
#if canImport(Darwin)
import Darwin
#endif

public enum PeerIdentity {
    /// What kind of signature is on the daemon itself. Cached at
    /// startup; never recomputed.
    public enum SelfIdentity: Sendable {
        case developerID(
            teamID: String,
            daemonBundleID: String,
            expectedHostBundleID: String
        )
        case adHoc(
            cdHashHex: String,
            daemonBundleID: String,
            expectedHostBundleID: String,
            processDir: URL
        )
        case unsigned

        public var expectedHostBundleID: String? {
            switch self {
            case let .developerID(_, _, expected):
                return expected

            case let .adHoc(_, _, expected, _):
                return expected

            case .unsigned:
                return nil
            }
        }
    }

    public enum ValidationResult: Sendable, Equatable {
        case production(peerTeamID: String, peerBundleID: String)
        case adHocFromSameBuild(peerBundleID: String, peerCDHashHex: String)
        /// A genuine, stable signature mismatch: the peer's identity was
        /// read and does not match the daemon's. Safe to cache.
        case rejected(reason: String)
        /// The peer's identity could not be determined: the `SecCode`
        /// couldn't be resolved, its signing info couldn't be read, or
        /// the daemon itself is unsigned. This is a **non-cacheable**
        /// validation failure, NOT a signature mismatch: callers deny the
        /// attempt but must **not** cache it. Some causes are transient
        /// (a one-time Security-framework hiccup, which then recovers on
        /// retry); others are stable for the daemon's lifetime (unsigned
        /// daemon): either way it must not poison the cache.
        case unavailable(reason: String)
    }

    private struct SigningInfo {
        let bundleID: String?
        let teamID: String?
        let cdHashHex: String?
        let executablePath: URL?
        /// `true` if the `kSecCodeInfoFlags` field has the
        /// `kSecCodeSignatureAdhoc` bit set.
        let adHocFlag: Bool
    }

    /// Cached identity of the running daemon. Reading at startup
    /// and once is correct: the daemon's binary doesn't change
    /// mid-process.
    public static let selfIdentity: SelfIdentity = computeSelfIdentity()

    /// Validate an XPC peer's audit token against the daemon's
    /// own signature.
    public static func validateGUIPeer(
        audit token: audit_token_t
    ) -> ValidationResult {
        let expectedHostBundleID = selfIdentity.expectedHostBundleID
        guard let expectedHostBundleID else {
            return .unavailable(reason: "daemon is unsigned; cannot validate peer")
        }
        guard let peerCode = secCode(forAuditToken: token) else {
            return .unavailable(reason: "could not resolve SecCode for peer")
        }
        let peerInfo: SigningInfo
        do {
            peerInfo = try signingInformation(secCode: peerCode)
        } catch {
            return .unavailable(reason: "could not read peer signing info: \(error)")
        }
        let peerBundleID = peerInfo.bundleID ?? ""
        guard peerBundleID == expectedHostBundleID else {
            return .rejected(
                reason: "peer bundle id \(peerBundleID) "
                    + "!= expected \(expectedHostBundleID)"
            )
        }
        switch selfIdentity {
        case let .developerID(teamID, _, _):
            // Production: peer must also be Developer-ID-signed
            // and share the team identifier.
            guard peerInfo.adHocFlag == false else {
                return .rejected(
                    reason: "peer is ad-hoc-signed but daemon is Developer-ID"
                )
            }
            guard let peerTeamID = peerInfo.teamID else {
                return .rejected(
                    reason: "peer signature has no team identifier"
                )
            }
            guard peerTeamID == teamID else {
                return .rejected(
                    reason: "peer team \(peerTeamID) != daemon team \(teamID)"
                )
            }
            return .production(
                peerTeamID: peerTeamID,
                peerBundleID: peerBundleID
            )

        case let .adHoc(_, _, _, processDir):
            // Edge case: only accepted when both binaries are
            // ad-hoc-signed from the same build tree.
            guard peerInfo.adHocFlag else {
                return .rejected(
                    reason: "peer is Developer-ID-signed but daemon is ad-hoc"
                )
            }
            guard let peerPath = peerInfo.executablePath else {
                return .unavailable(reason: "peer executable path unavailable")
            }
            guard isSiblingPath(peerExecutable: peerPath, daemonDir: processDir)
            else {
                return .rejected(
                    reason: "peer path \(peerPath.path) is not a sibling "
                        + "of daemon dir \(processDir.path)"
                )
            }
            return .adHocFromSameBuild(
                peerBundleID: peerBundleID,
                peerCDHashHex: peerInfo.cdHashHex ?? ""
            )

        case .unsigned:
            return .unavailable(reason: "daemon is unsigned; mint refused")
        }
    }

    // MARK: - Internals

    private static func computeSelfIdentity() -> SelfIdentity {
        var secCode: SecCode?
        let status = SecCodeCopySelf([], &secCode)
        guard status == errSecSuccess, let secCode else {
            return .unsigned
        }
        guard let info = try? signingInformation(secCode: secCode) else {
            return .unsigned
        }
        let daemonBundleID = info.bundleID ?? "(unknown)"
        let expectedHostBundleID = expectedHostBundleID(
            daemonBundleID: daemonBundleID
        )
        let processDir = info.executablePath?.deletingLastPathComponent()
            ?? URL(fileURLWithPath: "/")
        if info.adHocFlag {
            return .adHoc(
                cdHashHex: info.cdHashHex ?? "",
                daemonBundleID: daemonBundleID,
                expectedHostBundleID: expectedHostBundleID,
                processDir: processDir
            )
        }
        if let teamID = info.teamID, !teamID.isEmpty {
            return .developerID(
                teamID: teamID,
                daemonBundleID: daemonBundleID,
                expectedHostBundleID: expectedHostBundleID
            )
        }
        // Signed but no team identifier: treat as unsigned for
        // the automation gate (a developer cert without team
        // shouldn't reach automation scope).
        return .unsigned
    }

    private static func signingInformation(secCode: SecCode) throws -> SigningInfo {
        // SecCodeCopySigningInformation needs a SecStaticCode,
        // not a SecCode; one hop through SecCodeCopyStaticCode.
        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(secCode, [], &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else {
            throw NSError(
                domain: "PeerIdentity",
                code: Int(staticStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "SecCodeCopyStaticCode failed: \(staticStatus)"
                ]
            )
        }
        var infoRef: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &infoRef
        )
        guard infoStatus == errSecSuccess, let infoRef else {
            throw NSError(
                domain: "PeerIdentity",
                code: Int(infoStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "SecCodeCopySigningInformation failed: \(infoStatus)"
                ]
            )
        }
        let dictionary = infoRef as NSDictionary
        let bundleID = dictionary[kSecCodeInfoIdentifier as String] as? String
        let teamID = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        let cdHashData = dictionary[kSecCodeInfoUnique as String] as? Data
        let cdHashHex = cdHashData.map { hexEncode($0) }
        let flags = (dictionary[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        // `kSecCodeSignatureAdhoc` = 0x0002 from CSCommon.h. The
        // Security framework Swift import doesn't expose the
        // enum constants directly, so we open-code the bit.
        let adHocFlag = (flags & 0x0002) != 0
        var executablePath: URL?
        var executableRef: CFURL?
        let pathStatus = SecCodeCopyPath(
            staticCode,
            [],
            &executableRef
        )
        if pathStatus == errSecSuccess, let executableRef {
            executablePath = executableRef as URL
        }
        return SigningInfo(
            bundleID: bundleID,
            teamID: teamID,
            cdHashHex: cdHashHex,
            executablePath: executablePath,
            adHocFlag: adHocFlag
        )
    }

    /// Resolve the peer's `SecCode` from its **full audit token**, not
    /// its pid. `kSecGuestAttributeAudit` ties the lookup to the exact
    /// process instance the token names (the token embeds the
    /// pid-generation), so it can't be satisfied by a different process
    /// that reused the pid after the original exited: the race a
    /// pid-only (`kSecGuestAttributePid`) lookup is subject to, widened
    /// here because validation runs in a detached task.
    private static func secCode(forAuditToken token: audit_token_t) -> SecCode? {
        var mutableToken = token
        let tokenData = withUnsafeBytes(of: &mutableToken) { Data($0) } as CFData
        let attributes: CFDictionary = [
            kSecGuestAttributeAudit as String: tokenData
        ] as CFDictionary
        var secCode: SecCode?
        let status = SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            [],
            &secCode
        )
        guard status == errSecSuccess else { return nil }
        return secCode
    }

    /// Strip the `.daemon` suffix off the daemon bundle id, if
    /// present. The rebrand convention is `<host>.daemon` for the
    /// helper bundle id; the host bundle id is the prefix.
    public static func expectedHostBundleID(daemonBundleID: String) -> String {
        let suffix = ".daemon"
        if daemonBundleID.hasSuffix(suffix) {
            return String(daemonBundleID.dropLast(suffix.count))
        }
        return daemonBundleID
    }

    /// Sibling-path check: the peer's executable lives in the
    /// same `.build/<config>/` directory or the same `.app` bundle
    /// root as the daemon. Catches "both binaries built ad-hoc
    /// in the same tree" while rejecting unrelated same-user
    /// processes.
    public static func isSiblingPath(
        peerExecutable: URL,
        daemonDir: URL
    ) -> Bool {
        let peerStandardized = peerExecutable.standardizedFileURL
            .deletingLastPathComponent()
        let daemonStandardized = daemonDir.standardizedFileURL
        if peerStandardized.path == daemonStandardized.path { return true }
        // For .app bundles, both binaries live under
        // `…/<bundle>.app/Contents/…`: accept when they share
        // any common ancestor ending in `.app`.
        let peerComponents = peerStandardized.pathComponents
        let daemonComponents = daemonStandardized.pathComponents
        for ancestor in peerComponents.indices.reversed()
        where peerComponents[ancestor].hasSuffix(".app") {
            let prefix = peerComponents[0...ancestor]
            if daemonComponents.count >= prefix.count,
                Array(daemonComponents[0..<prefix.count]) == Array(prefix) {
                return true
            }
        }
        return false
    }

    private static func hexEncode(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
