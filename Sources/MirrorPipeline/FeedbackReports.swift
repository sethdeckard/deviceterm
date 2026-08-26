// SPDX-License-Identifier: GPL-3.0-or-later
/// The RTCP feedback datagrams sent back to the device over the shared RTP
/// socket. Two are load-bearing for a stable mirror:
///
/// - **Receiver Report**: the device's encoder stalls within ~25s without a
///   periodic RR, freezing the picture. One per second while packets flow keeps
///   it producing frames.
/// - **Picture Loss Indication**: asks the encoder for a fresh IDR after loss;
///   without it a long-GOP stream can sit frozen on the last good keyframe
///   indefinitely.
///
/// SSRC perspective: in a packet deviceterm sends, `senderSSRC` is ours and
/// `mediaSSRC` is the device's.
enum FeedbackReports {
    /// A minimal Receiver Report (RFC 3550 §6.4.2): 32 bytes, one report block,
    /// all loss/jitter fields zero. The device only needs the RR to exist (with
    /// a plausible highest sequence) to keep the encoder alive.
    static func receiverReport(senderSSRC: UInt32, mediaSSRC: UInt32, highestSequence: UInt32) -> [UInt8] {
        var packet: [UInt8] = [0x81, 0xC9] // V=2 P=0 RC=1 · PT=201 (RR)
        packet += beUInt16(7) // length = 7 (8 words total)
        packet += beUInt32(senderSSRC) // our SSRC
        packet += beUInt32(mediaSSRC) // device's SSRC (reported on)
        packet += [0] // fraction lost
        packet += [0, 0, 0] // cumulative packets lost (24-bit)
        // Highest sequence received: the raw 16-bit RTP sequence placed in the
        // 32-bit field. The loss policy doesn't track sequence cycles, so this
        // wraps to zero rather than accumulating a cycle count.
        packet += beUInt32(highestSequence)
        packet += beUInt32(0) // interarrival jitter
        packet += beUInt32(0) // last SR timestamp (none received)
        packet += beUInt32(0) // delay since last SR
        return packet
    }

    /// A Picture Loss Indication (RFC 4585 §6.3.1): 12 bytes.
    static func pictureLossIndication(senderSSRC: UInt32, mediaSSRC: UInt32) -> [UInt8] {
        var packet: [UInt8] = [0x81, 0xCE] // V=2 P=0 FMT=1 · PT=206 (PSFB)
        packet += beUInt16(2) // length = 2 (3 words total)
        packet += beUInt32(senderSSRC) // our SSRC
        packet += beUInt32(mediaSSRC) // device's SSRC (media source)
        return packet
    }

    private static func beUInt16(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(value & 0xFF)]
    }

    private static func beUInt32(_ value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
    }
}
