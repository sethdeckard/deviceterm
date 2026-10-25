// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Metal

/// Copies one drawn frame back off the GPU, for the dev seat's pane
/// snapshots (`PaneSnapshotWriter`).
///
/// Encoded into the frame's own command buffer, after its render pass and
/// before it presents, so what comes back is exactly what was shown. The
/// drawable has to be readable, which a view that isn't `framebufferOnly`
/// gives; one that is delivers nil.
///
/// Each readback settles exactly once: with the frame once its command buffer
/// completes, or with nil when the draw never gets that far. A burst waits on
/// every frame it was promised, so one left unsettled would hang it.
@MainActor
final class SimulatorFrameReadback {
    /// Called once, on a Metal completion thread or the main thread, with
    /// the frame or nil.
    private let deliver: @Sendable (PaneSnapshotWriter.Image?) -> Void
    /// Whether `deliver` has been called, or handed to a command buffer that
    /// will call it.
    private var settled = false

    init(deliver: @escaping @Sendable (PaneSnapshotWriter.Image?) -> Void) {
        self.deliver = deliver
    }

    /// A BGRA texture's pixels as an image.
    nonisolated private static func image(from texture: MTLTexture) -> CGImage? {
        let bytesPerRow = texture.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        texture.getBytes(
            &bytes,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0
        )
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: texture.width,
            height: texture.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// Copy `texture` out once `commandBuffer` completes. The caller must
    /// commit the buffer after this.
    func encode(from texture: MTLTexture, into commandBuffer: MTLCommandBuffer) {
        guard !settled else { return }
        guard !texture.isFramebufferOnly, texture.pixelFormat == .bgra8Unorm else {
            settleUnread()
            return
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: texture.width,
            height: texture.height,
            mipmapped: false
        )
        descriptor.storageMode = texture.device.hasUnifiedMemory ? .shared : .managed
        guard let staging = texture.device.makeTexture(descriptor: descriptor),
            let blit = commandBuffer.makeBlitCommandEncoder()
        else {
            settleUnread()
            return
        }
        blit.copy(from: texture, to: staging)
        if staging.storageMode == .managed { blit.synchronize(resource: staging) }
        blit.endEncoding()
        settled = true
        let deliver = deliver
        nonisolated(unsafe) let staged = staging
        commandBuffer.addCompletedHandler { buffer in
            guard buffer.status == .completed else {
                deliver(nil)
                return
            }
            deliver(Self.image(from: staged).map { PaneSnapshotWriter.Image(image: $0) })
        }
    }

    /// Settle with nil, unless the frame is already on its way: for a draw
    /// that returned before reaching `encode`, or failed inside it.
    func settleUnread() {
        guard !settled else { return }
        settled = true
        deliver(nil)
    }
}
