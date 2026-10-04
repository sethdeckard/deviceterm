// SPDX-License-Identifier: GPL-3.0-or-later

import CoreVideo
import Foundation
import IOSurface
import Metal

/// Copies one BGRA IOSurface into another of the same size with a Metal blit,
/// so a full-frame copy costs the daemon an encode and a commit rather than a
/// CPU pass over every byte.
///
/// For a pool slot it keeps the CPU copy's guarantees. The pool's holds keep
/// consumers off the slot being written, and `blit` returns only once the GPU
/// has completed, so a published slot is never half-written. The source is
/// read without `IOSurfaceLock`; nothing orders the blit against the
/// producer's next render into it.
///
/// Textures are cached per surface, because the simulator's framebuffer is one
/// stable surface and slots persist within a pool epoch. A cached texture
/// keeps its surface alive, so the cache drops every entry whose size differs
/// from the latest destination's (a rotation) and evicts the least recently
/// used beyond `cacheCapacity`.
///
/// `@unchecked Sendable`: `device` and `commandQueue` are thread-safe Metal
/// objects, and `textures` and `useClock` are touched only on `queue`.
final class SurfaceBlitter: @unchecked Sendable {
    /// One surface's texture, with when it was last used.
    private struct CachedTexture {
        let texture: any MTLTexture
        var lastUse: UInt64
    }

    /// What a committed blit reports once the GPU completes it.
    ///
    /// `@unchecked Sendable`: written on `queue` by the block that commits the
    /// blit, and read on `queue` by the completion, which hops there and so
    /// runs after that block returns.
    private final class PendingBlit: @unchecked Sendable {
        var bytes = 0
        var cpuNanoseconds: UInt64 = 0
    }

    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let queue = DispatchQueue(label: "com.deviceterm.surface-blit", qos: .userInteractive)
    private let cacheCapacity: Int
    private var textures: [ObjectIdentifier: CachedTexture] = [:]
    private var useClock: UInt64 = 0

    /// How many textures the cache holds.
    var cachedTextureCount: Int { queue.sync { textures.count } }

    /// Nil without a Metal device or command queue, in which case the caller
    /// keeps copying on the CPU. `cacheCapacity` bounds the cached textures;
    /// size it to the pool's slot ceiling plus the source.
    init?(cacheCapacity: Int) {
        guard let device = MTLCreateSystemDefaultDevice(), let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        self.device = device
        self.commandQueue = commandQueue
        self.cacheCapacity = max(cacheCapacity, 2)
    }

    /// Whether `blit` can copy `source` into `destination`: both BGRA, same
    /// width and height.
    static func canBlit(from source: IOSurfaceRef, to destination: IOSurfaceRef) -> Bool {
        IOSurfaceGetPixelFormat(source) == kCVPixelFormatType_32BGRA
            && IOSurfaceGetPixelFormat(destination) == kCVPixelFormatType_32BGRA
            && IOSurfaceGetWidth(source) == IOSurfaceGetWidth(destination)
            && IOSurfaceGetHeight(source) == IOSurfaceGetHeight(destination)
            && IOSurfaceGetWidth(destination) > 0
            && IOSurfaceGetHeight(destination) > 0
    }

    /// Blit `source` into `destination` and wait for the GPU to finish it.
    /// Returns the bytes `SurfaceCopy.copy` would report for the same pair
    /// (the narrower stride × height), and the CPU time spent preparing,
    /// encoding, and committing the blit. `bytes` is nil when the pair can't
    /// be blitted, a texture or command buffer can't be made, or the GPU
    /// didn't complete the blit; the caller then copies on the CPU, and the
    /// CPU time still covers the failed attempt.
    ///
    /// Once a blit is committed this waits for the GPU even if the calling
    /// task is cancelled. Returning early would let the caller release its
    /// hold on `destination`, or start a CPU copy into it, while the GPU is
    /// still writing it.
    func blit(
        from source: RetainedSurface,
        to destination: RetainedSurface
    ) async -> (bytes: Int?, cpuNanoseconds: UInt64) {
        await withCheckedContinuation { continuation in
            queue.async {
                let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                let pending = PendingBlit()
                let bytes = source.withRef { origin in
                    destination.withRef { target in
                        self.commit(from: origin, to: target) { succeeded in
                            self.queue.async {
                                continuation.resume(
                                    returning: (succeeded ? pending.bytes : nil, pending.cpuNanoseconds)
                                )
                            }
                        }
                    }
                }
                let cpuNanoseconds = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- start
                guard let bytes else {
                    continuation.resume(returning: (nil, cpuNanoseconds))
                    return
                }
                pending.bytes = bytes
                pending.cpuNanoseconds = cpuNanoseconds
            }
        }
    }

    /// Drop every cached texture, releasing the surfaces they keep alive.
    /// Call it once a frame run has ended, so a paused pane's retired slots
    /// can be freed. A blit still in flight keeps its own textures until the
    /// GPU completes it.
    func purge() {
        queue.async { self.textures.removeAll() }
    }
}

private extension SurfaceBlitter {
    /// Encode and commit the blit, with `onCompletion` reporting whether the
    /// GPU completed it. Returns the bytes the blit covers, or nil when
    /// nothing was committed. Runs on `queue`.
    func commit(
        from source: IOSurfaceRef,
        to destination: IOSurfaceRef,
        onCompletion: @escaping @Sendable (Bool) -> Void
    ) -> Int? {
        guard Self.canBlit(from: source, to: destination) else { return nil }
        let width = IOSurfaceGetWidth(destination)
        let height = IOSurfaceGetHeight(destination)
        textures = textures.filter { $0.value.texture.width == width && $0.value.texture.height == height }
        guard let sourceTexture = texture(for: source) else { return nil }
        guard let destinationTexture = texture(for: destination) else { return nil }
        evictBeyondCapacity()
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }
        guard let encoder = commandBuffer.makeBlitCommandEncoder() else { return nil }
        encoder.copy(from: sourceTexture, to: destinationTexture)
        encoder.endEncoding()
        commandBuffer.addCompletedHandler { buffer in
            onCompletion(buffer.status == .completed)
        }
        commandBuffer.commit()
        return min(IOSurfaceGetBytesPerRow(source), IOSurfaceGetBytesPerRow(destination)) * height
    }

    /// The cached texture for `surface`, made on first use.
    func texture(for surface: IOSurfaceRef) -> (any MTLTexture)? {
        useClock += 1
        let key = ObjectIdentifier(surface)
        if let cached = textures[key] {
            textures[key]?.lastUse = useClock
            return cached.texture
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: IOSurfaceGetWidth(surface),
            height: IOSurfaceGetHeight(surface),
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else {
            return nil
        }
        textures[key] = CachedTexture(texture: texture, lastUse: useClock)
        return texture
    }

    /// Drop the least recently used textures until the cache fits.
    func evictBeyondCapacity() {
        while textures.count > cacheCapacity {
            guard let oldest = textures.min(by: { $0.value.lastUse < $1.value.lastUse }) else { return }
            textures.removeValue(forKey: oldest.key)
        }
    }
}
