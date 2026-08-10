// SPDX-License-Identifier: GPL-3.0-or-later

import Testing

@testable import MirrorPipeline

/// Byte-exact RFC-layout vectors for the RTCP feedback packets. The device
/// parses by field offset, so a wrong one silently disables the keep-alive
/// (encoder stalls) or the keyframe request (mirror stays frozen after loss).
struct FeedbackReportsTests {
    private static let senderSSRC: UInt32 = 0x1A2B_3C4D
    private static let mediaSSRC: UInt32 = 0x5E6F_7A8B

    @Test("the receiver report matches the RFC 3550 §6.4.2 layout")
    func receiverReportLayout() {
        let report = FeedbackReports.receiverReport(
            senderSSRC: Self.senderSSRC, mediaSSRC: Self.mediaSSRC, highestSequence: 0x0001_2345
        )
        let expected = [UInt8](
            hexString: "81c90007" + "1a2b3c4d" + "5e6f7a8b"
                + "00" + "000000" + "00012345" + "00000000" + "00000000" + "00000000"
        )
        #expect(report == expected)
        #expect(report.count == 32)
    }

    @Test("the picture loss indication matches the RFC 4585 §6.3.1 layout")
    func pliLayout() {
        let pli = FeedbackReports.pictureLossIndication(senderSSRC: Self.senderSSRC, mediaSSRC: Self.mediaSSRC)
        #expect(pli == [UInt8](hexString: "81ce0002" + "1a2b3c4d" + "5e6f7a8b"))
        #expect(pli.count == 12)
    }
}
