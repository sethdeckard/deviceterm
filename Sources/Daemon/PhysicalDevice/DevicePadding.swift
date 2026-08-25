// SPDX-License-Identifier: GPL-3.0-or-later
//
// DevicePadding: detect the real content rectangle inside a decoded
// physical-device frame.
//
// A device's HEVC mirror doesn't arrive at the panel's exact pixel size.
// The encoder pads the picture width up to a macroblock boundary (e.g. a
// 1207-wide screen becomes a 1216-wide coded picture) and VideoToolbox can
// over-allocate the output IOSurface's height (e.g. 2624 → 2656). Both
// extras are filled with pure-black (0,0,0) on the right and bottom edges,
// and neither the clean aperture nor the stream-negotiation metadata reports
// the true visible size. Rendered as-is, that padding shows as black strips
// between the screen content and the bezel.
//
// The content is always anchored top-left, and the padding is always exactly
// zero (real content essentially never is across a whole edge run), so the
// real content size is the bottom-right-most non-black pixel. This is pure +
// IOSurface-only so it's unit-testable with a synthetic padded surface.

import Foundation
import IOSurface

enum DevicePadding {
    /// A pixel channel at or below this counts as padding. The encoder /
    /// VideoToolbox fill isn't pure zero. It's near-black, plus a column or
    /// two of faint bleed (brightness ~9–15) at the content↔padding boundary,
    /// so an exact-zero test never engages the crop and a too-low floor
    /// leaves a hairline of bleed. Live measurement (iPhone 16 Pro) showed the
    /// content edge stabilizing at the true panel width for every threshold
    /// from 16 up; 24 clears the bleed with margin while staying far below any
    /// real content, which is never this dark across a whole edge run.
    static let blackThreshold: UInt8 = 24
    /// The real content size within `surface` (BGRA, top-left anchored), or
    /// `nil` when the frame can't be sized confidently: either fully black,
    /// or padded by more than `maxTrim` on an edge (a too-dark frame whose
    /// real content happens to reach neither edge). A `nil` return means
    /// "don't crop this frame, try the next one", so a black first frame on
    /// connect can't lock in an over-crop.
    ///
    /// `maxTrim` bounds how much is ever trimmed per axis: padding beyond it
    /// is treated as untrusted (returns nil) rather than eating real content.
    static func contentSize(of surface: IOSurfaceRef, maxTrim: Int = 64) -> (width: Int, height: Int)? {
        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        guard width > 0, height > 0 else { return nil }
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
        let pixels = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)

        func isNonBlack(_ pixelX: Int, _ pixelY: Int) -> Bool {
            let pixel = pixels + pixelY * bytesPerRow + pixelX * 4
            return pixel[0] > blackThreshold || pixel[1] > blackThreshold || pixel[2] > blackThreshold
        }

        // Content is top-left anchored and any padding is at most `maxTrim`, so the
        // content's right edge lies in the last `maxTrim + 1` columns and its bottom
        // edge in the last `maxTrim + 1` rows. Scan only those two edge bands, not
        // the whole frame: the full scan was ~3.2M pixels on the frame-delivery path
        // (~0.5s in debug) and re-ran forever on a dark frame that returns nil,
        // stalling the mirror. Edge bands are ~13× cheaper and equivalent, since
        // maxX/maxY beyond the band already exceed maxTrim (→ nil either way). The
        // `+ 1` includes the last content column/row when padding is exactly
        // `maxTrim` (content edge at `width - maxTrim - 1`), and makes `maxTrim: 0`
        // scan the final column/row rather than an empty range.
        let xFloor = max(0, width - maxTrim - 1)
        let yFloor = max(0, height - maxTrim - 1)
        var maxX = -1
        for pixelX in stride(from: width - 1, through: xFloor, by: -1)
        where (0..<height).contains(where: { isNonBlack(pixelX, $0) }) {
            maxX = pixelX
            break
        }
        var maxY = -1
        for pixelY in stride(from: height - 1, through: yFloor, by: -1)
        where (0..<width).contains(where: { isNonBlack($0, pixelY) }) {
            maxY = pixelY
            break
        }
        guard maxX >= 0, maxY >= 0 else { return nil }
        let contentWidth = maxX + 1
        let contentHeight = maxY + 1
        guard width - contentWidth <= maxTrim, height - contentHeight <= maxTrim else { return nil }
        return (contentWidth, contentHeight)
    }
}
