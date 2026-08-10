// SPDX-License-Identifier: GPL-3.0-or-later

import CoreVideo

/// One decoded mirror frame: a decoder-owned `CVPixelBuffer`.
///
/// The pipeline hands out the decoder's own buffer and never publishes it
/// itself: a consumer that intends to keep or share the pixels MUST copy them
/// into its own storage before yielding control, because VideoToolbox recycles
/// its pool and a later frame can overwrite this one's backing. Hold the buffer
/// until that copy completes.
///
/// `@unchecked Sendable`: a `CVPixelBuffer` is a reference type Swift can't prove
/// safe to share, but the pipeline yields each frame to a single consumer and
/// keeps no reference of its own past the yield, and the consumer's contract is
/// to copy-then-release, so the buffer is never touched from two places at once.
package struct DecodedFrame: @unchecked Sendable {
    package let pixelBuffer: CVPixelBuffer

    package init(pixelBuffer: CVPixelBuffer) {
        self.pixelBuffer = pixelBuffer
    }
}
