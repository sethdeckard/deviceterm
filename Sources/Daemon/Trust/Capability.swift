// SPDX-License-Identifier: GPL-3.0-or-later
//
// Capability: the per-session secret that authenticates messages
// claiming to originate from a specific session.
//
// 32 bytes of cryptographically random data, generated once at
// `session.create` and exposed to the session's shell tree via the
// `DEVICETERM_SESSION_CAP` env var (as base64). Every subsequent shim
// event and CLI request that names a `sessionId` must also carry
// the matching `cap` on the wire; the server rejects mismatches.
//
// Wire encoding is base64: JSON-friendly, exact length-preserving,
// matches what gets pasted into the env var.

import Foundation
import Security

public struct Capability: Sendable, Hashable {
    /// Standard byte count for newly-generated capabilities. 32 bytes
    /// = 256 bits, well above any practical brute-force boundary;
    /// this is the same magnitude.
    public static let standardByteCount: Int = 32

    public let bytes: Data

    /// Base64-encoded representation. Stable round-trips through the
    /// wire encoding; safe to copy/paste into env vars (no padding
    /// issues with the standard alphabet for 32-byte inputs).
    public var token: String {
        bytes.base64EncodedString()
    }

    public init(bytes: Data) {
        self.bytes = bytes
    }

    /// Decode from the base64 wire form. Returns nil on invalid
    /// encoding; callers convert that to an `invalidParams` error.
    public init?(token: String) {
        guard let bytes = Data(base64Encoded: token) else { return nil }
        self.bytes = bytes
    }

    /// Generate a cryptographically random capability. Throws if the
    /// system RNG isn't available (effectively never on macOS, but
    /// we propagate the failure rather than silently producing a
    /// weak token).
    public static func random(byteCount: Int = standardByteCount) throws -> Capability {
        var buf = Data(count: byteCount)
        let status = buf.withUnsafeMutableBytes { rawBuf -> Int32 in
            guard let base = rawBuf.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, byteCount, base)
        }
        guard status == errSecSuccess else {
            throw CapabilityError.randomGenerationFailed(status: Int(status))
        }
        return Capability(bytes: buf)
    }
}

extension Capability: Equatable {
    /// Constant-time byte-wise comparison. Even though 32 random
    /// bytes make brute-force impractical, the comparison stays
    /// constant-time so timing-based side channels can't peel the
    /// secret off one byte at a time.
    public static func == (lhs: Capability, rhs: Capability) -> Bool {
        guard lhs.bytes.count == rhs.bytes.count else { return false }
        var accumulator: UInt8 = 0
        for index in 0..<lhs.bytes.count {
            accumulator |= lhs.bytes[lhs.bytes.startIndex + index]
                ^ rhs.bytes[rhs.bytes.startIndex + index]
        }
        return accumulator == 0
    }
}
