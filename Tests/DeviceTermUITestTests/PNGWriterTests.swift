// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import DeviceTermUITest

@Suite("PNG encoding")
struct PNGWriterTests {
    /// A solid-red bitmap, standing in for a captured window.
    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let context = try #require(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func readBackSize(_ path: String) throws -> (width: Int, height: Int) {
        let url = URL(fileURLWithPath: path) as CFURL
        let source = try #require(CGImageSourceCreateWithURL(url, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (image.width, image.height)
    }

    @Test
    func writesAPNGAtTheImagesNativePixelSize() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dt-uitest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("shot.png").path

        // 2x of a 100x50-point window: the Retina case.
        try PNGWriter.write(try makeImage(width: 200, height: 100), to: path)

        #expect(FileManager.default.fileExists(atPath: path))
        let size = try readBackSize(path)
        #expect(size.width == 200)
        #expect(size.height == 100)
    }

    /// The harness writes wherever the agent asks, including a scratch
    /// directory that doesn't exist yet.
    @Test
    func createsMissingParentDirectories() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dt-uitest-\(UUID().uuidString)")
            .appendingPathComponent("nested/deeper")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("shot.png").path

        try PNGWriter.write(try makeImage(width: 4, height: 4), to: path)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    /// An unwritable destination surfaces as a thrown error rather than a
    /// silently-missing file. (The parent-directory creation fails first
    /// here, so this is a `CocoaError`, not `PNGWriterError`; the
    /// contract under test is "it throws", not which type.)
    @Test
    func refusesAnUnwritablePath() throws {
        let image = try makeImage(width: 4, height: 4)
        #expect(throws: (any Error).self) {
            try PNGWriter.write(image, to: "/dev/null/nope/shot.png")
        }
    }
}
