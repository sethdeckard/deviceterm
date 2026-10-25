// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes one snapshot burst to disk: each frame as a PNG, composited over
/// the bezel drawn behind it, then `frames.json` listing them.
///
/// Frames arrive from Metal's completion threads, after the draw that took
/// them, so the burst can't be wrapped up when its time runs out: it waits
/// for every frame it was promised (`expectFrame()`) before it writes the
/// list and reports.
///
/// `@unchecked Sendable` because every stored property past `init` is read
/// and written only on `queue`, which is serial.
final class PaneSnapshotWriter: @unchecked Sendable {
    /// A `CGImage` handed between threads. CoreGraphics images are immutable
    /// once made, which is the invariant that makes crossing safe.
    struct Image: @unchecked Sendable {
        let image: CGImage
    }

    private let queue = DispatchQueue(label: "com.deviceterm.pane-snapshot")
    private let directory: URL
    private var frames: [PaneSnapshotFrame] = []
    private var pending = 0
    private var completion: (@Sendable (PaneSnapshotOutcome) -> Void)?
    private var failure: String?

    /// A writer into `directory`, which is created if missing.
    init(directory: String) throws {
        self.directory = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    /// `picture` drawn over `bezel`, at the picture's size. The pane draws
    /// its bezel in a layer under the Metal view, and the Metal view clears
    /// to transparent outside the screen, so this is what the pane shows.
    static func composite(picture: CGImage, over bezel: CGImage?) -> CGImage? {
        let rect = CGRect(x: 0, y: 0, width: picture.width, height: picture.height)
        guard let context = CGContext(
            data: nil,
            width: picture.width,
            height: picture.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        if let bezel { context.draw(bezel, in: rect) }
        context.draw(picture, in: rect)
        return context.makeImage()
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Promise one more frame. Call before the frame's pixels can arrive,
    /// on the thread that will later call `finish`.
    func expectFrame() {
        queue.async { self.pending += 1 }
    }

    /// Write a promised frame. A nil `picture` (the readback failed, as for a
    /// drawable that couldn't be read back yet) keeps the promise without a
    /// file.
    func deliver(
        index: Int,
        seconds: Double,
        state: PaneSnapshotFrame.State,
        picture: Image?,
        bezel: Image?
    ) {
        queue.async {
            defer {
                self.pending -= 1
                self.reportIfDone()
            }
            guard let picture else { return }
            let file = String(format: "%04d.png", index)
            guard let composited = Self.composite(picture: picture.image, over: bezel?.image) else {
                self.failure = self.failure ?? "could not composite frame \(index)"
                return
            }
            do {
                try Self.writePNG(composited, to: self.directory.appendingPathComponent(file))
                self.frames.append(PaneSnapshotFrame(index: index, file: file, seconds: seconds, state: state))
            } catch {
                self.failure = self.failure ?? "could not write \(file): \(error)"
            }
        }
    }

    /// Stop taking frames, and report once every promised one is written or
    /// skipped.
    func finish(completion: @escaping @Sendable (PaneSnapshotOutcome) -> Void) {
        queue.async {
            self.completion = completion
            self.reportIfDone()
        }
    }

    private func reportIfDone() {
        guard pending == 0, let completion else { return }
        self.completion = nil
        frames.sort { $0.index < $1.index }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(frames).write(to: directory.appendingPathComponent("frames.json"))
        } catch {
            failure = failure ?? "could not write frames.json: \(error)"
        }
        if let failure {
            completion(PaneSnapshotOutcome(ok: false, frames: frames.count, error: failure))
        } else {
            completion(PaneSnapshotOutcome(ok: true, frames: frames.count, error: nil))
        }
    }
}
