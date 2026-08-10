// SPDX-License-Identifier: GPL-3.0-or-later
//
// RPCFraming: `[uint32 BE length][payload]` wire framing.
//
// Daemon and clients exchange framed JSON envelopes over a Unix
// domain socket. The framing is deliberately minimal: a 4-byte
// big-endian length prefix followed by exactly that many bytes of
// payload. The payload is opaque at this layer; `RPCEnvelope`
// interprets it as JSON.
//
// Why length-prefixed instead of newline-delimited: PTY byte streams
// and other binary-adjacent payloads (base64-encoded inside JSON)
// don't compose with newlines as a framing terminator. Length
// prefixes also make partial-read handling trivial: receivers
// accumulate into a buffer and call `decodeNext(from:)` until it
// returns nil.

import Foundation

public enum RPCFramingError: Error, Equatable, Sendable {
    /// Length-prefix decoded to a value larger than the configured cap.
    case payloadTooLarge(
        declared:
        Int,
        cap: Int
        )
}

/// Pure framing primitives, no I/O. Tests exercise these directly;
/// the actual socket code wraps them in a read/write loop.
public enum RPCFraming {
    /// Maximum payload size the daemon will accept in a single frame.
    /// 16 MiB is comfortably larger than any envelope we expect (PTY
    /// chunks cap at 16 KB; the bridge's largest tree dump is well
    /// under 1 MiB), and small enough to catch corruption-induced
    /// runaway allocations.
    public static let defaultPayloadCap: Int = 16 * 1_024 * 1_024

    /// Encode one frame: 4-byte big-endian length prefix + payload bytes.
    public static func encode(_ payload: Data) -> Data {
        let length = UInt32(payload.count).bigEndian
        var output = Data(capacity: 4 + payload.count)
        withUnsafeBytes(of: length) { output.append(contentsOf: $0) }
        output.append(payload)
        return output
    }

    /// Try to decode one frame from the head of `buffer`.
    ///
    /// - Returns `nil` if the buffer doesn't yet hold a full frame
    ///   (either the 4-byte prefix or the declared payload bytes).
    /// - Returns `(payload, consumed)` when a full frame is present:
    ///   the payload bytes and the total prefix+payload byte count the
    ///   caller should drop from the front of its read buffer.
    /// - Throws `payloadTooLarge` if the declared length exceeds
    ///   `cap` (defaulting to `defaultPayloadCap`). Receivers should
    ///   treat that as a connection-level fault and close.
    public static func decodeNext(
        from buffer: Data,
        cap: Int = RPCFraming.defaultPayloadCap
    ) throws -> (payload: Data, consumed: Int)? {
        guard buffer.count >= 4 else { return nil }
        let length = buffer.withUnsafeBytes { rawBuf -> UInt32 in
            // `loadUnaligned` because Data's storage isn't required to
            // be aligned; the BE bytes are at offset 0.
            let raw = rawBuf.loadUnaligned(as: UInt32.self)
            return UInt32(bigEndian: raw)
        }
        let payloadLength = Int(length)
        if payloadLength > cap {
            throw RPCFramingError.payloadTooLarge(declared: payloadLength, cap: cap)
        }
        let total = 4 + payloadLength
        guard buffer.count >= total else { return nil }
        // `buffer` may have a non-zero startIndex if a slice was passed;
        // convert offsets through `index(_:offsetBy:)` to stay safe.
        let payloadStart = buffer.index(buffer.startIndex, offsetBy: 4)
        let payloadEnd = buffer.index(buffer.startIndex, offsetBy: total)
        let payload = Data(buffer[payloadStart..<payloadEnd])
        return (payload: payload, consumed: total)
    }
}
