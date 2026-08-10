// SPDX-License-Identifier: GPL-3.0-or-later
//
// PNGWriter: encode a captured CGImage to a PNG file.
//
// Separate from `CaptureService` so it can be unit-tested against a
// synthetic image, with no GUI and no Screen Recording grant.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PNGWriterError: Error, Equatable {
    /// ImageIO refused to create or finalize the destination.
    case encodeFailed(path: String)
}

enum PNGWriter {
    /// Write `image` to `path` as PNG, creating parent directories.
    /// Pixels are written at the image's native size, so the caller is
    /// responsible for having captured at the display's backing scale; a
    /// Retina window then lands as a 2x-resolution PNG.
    static func write(_ image: CGImage, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else {
            throw PNGWriterError.encodeFailed(path: path)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw PNGWriterError.encodeFailed(path: path)
        }
    }
}
