// SPDX-License-Identifier: GPL-3.0-or-later

import CoreVideo
@testable import Daemon
import Foundation
import IOSurface
import Metal
import Testing

private let metalAvailable = MTLCreateSystemDefaultDevice() != nil

private func bgraSurface(width: Int, height: Int) throws -> RetainedSurface {
    RetainedSurface(try #require(SurfaceCopy.makeSurface(width: width, height: height)))
}

private func fillPattern(_ surface: RetainedSurface) {
    surface.withRef { ref in
        IOSurfaceLock(ref, [], nil)
        defer { IOSurfaceUnlock(ref, [], nil) }
        let count = IOSurfaceGetBytesPerRow(ref) * IOSurfaceGetHeight(ref)
        let bytes = IOSurfaceGetBaseAddress(ref).assumingMemoryBound(to: UInt8.self)
        for index in 0..<count { bytes[index] = UInt8(truncatingIfNeeded: index * 17 + index / 7) }
    }
}

/// The visible bytes of each row, leaving out stride padding.
private func visibleRows(_ surface: RetainedSurface) -> [[UInt8]] {
    surface.withRef { ref in
        IOSurfaceLock(ref, .readOnly, nil)
        defer { IOSurfaceUnlock(ref, .readOnly, nil) }
        let stride = IOSurfaceGetBytesPerRow(ref)
        let rowBytes = IOSurfaceGetWidth(ref) * 4
        let base = IOSurfaceGetBaseAddress(ref).assumingMemoryBound(to: UInt8.self)
        return (0..<IOSurfaceGetHeight(ref)).map { row in
            Array(UnsafeBufferPointer(start: base + row * stride, count: rowBytes))
        }
    }
}

@Test(.enabled(if: metalAvailable))
func aBlitReproducesTheSourcePixels() async throws {
    let blitter = try #require(SurfaceBlitter(cacheCapacity: 4))
    let source = try bgraSurface(width: 61, height: 23)
    let destination = try bgraSurface(width: 61, height: 23)
    fillPattern(source)
    let bytes = try #require(await blitter.blit(from: source, to: destination).bytes)
    #expect(visibleRows(destination) == visibleRows(source))
    #expect(bytes == destination.withRef { IOSurfaceGetBytesPerRow($0) * IOSurfaceGetHeight($0) })
}

@Test(.enabled(if: metalAvailable))
func aBlitRefusesMismatchedSizes() async throws {
    let blitter = try #require(SurfaceBlitter(cacheCapacity: 4))
    let source = try bgraSurface(width: 32, height: 16)
    let destination = try bgraSurface(width: 16, height: 32)
    #expect(await blitter.blit(from: source, to: destination).bytes == nil)
    #expect(blitter.cachedTextureCount == 0)
}

@Test
func onlyMatchingBGRASurfacesCanBlit() throws {
    let bgra = try bgraSurface(width: 8, height: 8)
    let properties: [IOSurfacePropertyKey: Any] = [
        .width: 8,
        .height: 8,
        .bytesPerElement: 4,
        .pixelFormat: kCVPixelFormatType_32ARGB
    ]
    let argb = RetainedSurface(try #require(IOSurfaceCreate(properties as CFDictionary)))
    let taller = try bgraSurface(width: 8, height: 9)
    bgra.withRef { bgraRef in
        argb.withRef { argbRef in
            #expect(!SurfaceBlitter.canBlit(from: argbRef, to: bgraRef))
            #expect(!SurfaceBlitter.canBlit(from: bgraRef, to: argbRef))
        }
        taller.withRef { tallerRef in
            #expect(!SurfaceBlitter.canBlit(from: bgraRef, to: tallerRef))
        }
        #expect(SurfaceBlitter.canBlit(from: bgraRef, to: bgraRef))
    }
}

@Test(.enabled(if: metalAvailable))
func aSizeChangeDropsTheOldSizesTextures() async throws {
    let blitter = try #require(SurfaceBlitter(cacheCapacity: 8))
    let portrait = (try bgraSurface(width: 16, height: 32), try bgraSurface(width: 16, height: 32))
    _ = try #require(await blitter.blit(from: portrait.0, to: portrait.1).bytes)
    #expect(blitter.cachedTextureCount == 2)
    let landscape = (try bgraSurface(width: 32, height: 16), try bgraSurface(width: 32, height: 16))
    _ = try #require(await blitter.blit(from: landscape.0, to: landscape.1).bytes)
    #expect(blitter.cachedTextureCount == 2)
}

@Test(.enabled(if: metalAvailable))
func theTextureCacheStaysWithinItsCapacity() async throws {
    let blitter = try #require(SurfaceBlitter(cacheCapacity: 3))
    let source = try bgraSurface(width: 16, height: 16)
    fillPattern(source)
    for _ in 0..<5 {
        let slot = try bgraSurface(width: 16, height: 16)
        _ = try #require(await blitter.blit(from: source, to: slot).bytes)
        #expect(visibleRows(slot) == visibleRows(source))
    }
    #expect(blitter.cachedTextureCount == 3)
}

@Test(.enabled(if: metalAvailable))
func aCancelledBlitStillWaitsForTheGPU() async throws {
    let blitter = try #require(SurfaceBlitter(cacheCapacity: 4))
    let source = try bgraSurface(width: 64, height: 64)
    let destination = try bgraSurface(width: 64, height: 64)
    fillPattern(source)
    let task = Task { await blitter.blit(from: source, to: destination) }
    task.cancel()
    #expect(await task.value.bytes != nil)
    #expect(visibleRows(destination) == visibleRows(source))
}

@Test(.enabled(if: metalAvailable))
func purgingEmptiesTheTextureCache() async throws {
    let blitter = try #require(SurfaceBlitter(cacheCapacity: 4))
    let source = try bgraSurface(width: 16, height: 16)
    let destination = try bgraSurface(width: 16, height: 16)
    _ = try #require(await blitter.blit(from: source, to: destination).bytes)
    #expect(blitter.cachedTextureCount == 2)
    blitter.purge()
    #expect(blitter.cachedTextureCount == 0)
}

@Test(.enabled(if: metalAvailable))
func aBlitReportsTheBytesTheCPUCopyWouldForMismatchedStrides() async throws {
    let blitter = try #require(SurfaceBlitter(cacheCapacity: 4))
    let properties: [IOSurfacePropertyKey: Any] = [
        .width: 16,
        .height: 8,
        .bytesPerElement: 4,
        .bytesPerRow: 256,
        .pixelFormat: kCVPixelFormatType_32BGRA
    ]
    let wide = RetainedSurface(try #require(IOSurfaceCreate(properties as CFDictionary)))
    let blitTarget = try bgraSurface(width: 16, height: 8)
    let copyTarget = try bgraSurface(width: 16, height: 8)
    try #require(wide.withRef(IOSurfaceGetBytesPerRow) != blitTarget.withRef(IOSurfaceGetBytesPerRow))
    fillPattern(wide)
    let blitted = try #require(await blitter.blit(from: wide, to: blitTarget).bytes)
    let copied = wide.withRef { origin in
        copyTarget.withRef { SurfaceCopy.copy(from: origin, to: $0) }
    }
    #expect(blitted == copied)
    #expect(visibleRows(blitTarget) == visibleRows(wide))
}
