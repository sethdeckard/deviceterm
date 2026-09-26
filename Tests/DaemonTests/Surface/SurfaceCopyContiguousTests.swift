// SPDX-License-Identifier: GPL-3.0-or-later

import CoreVideo
@testable import Daemon
import Foundation
import IOSurface
import Testing

private func surfaceWithStride(_ stride: Int, height: Int = 4) throws -> IOSurfaceRef {
    let properties: [IOSurfacePropertyKey: Any] = [
        .width: 13,
        .height: height,
        .bytesPerElement: 4,
        .bytesPerRow: stride,
        .pixelFormat: kCVPixelFormatType_32BGRA
    ]
    let surface = try #require(IOSurfaceCreate(properties as CFDictionary))
    try #require(IOSurfaceGetBytesPerRow(surface) == stride)
    return surface
}

private func fillSurface(_ surface: IOSurfaceRef, value: UInt8? = nil) {
    IOSurfaceLock(surface, [], nil)
    defer { IOSurfaceUnlock(surface, [], nil) }
    let count = IOSurfaceGetBytesPerRow(surface) * IOSurfaceGetHeight(surface)
    let bytes = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
    for index in 0..<count {
        bytes[index] = value ?? UInt8(truncatingIfNeeded: index * 17 + index / 7)
    }
}

private func surfaceBytes(_ surface: IOSurfaceRef) -> [UInt8] {
    IOSurfaceLock(surface, .readOnly, nil)
    defer { IOSurfaceUnlock(surface, .readOnly, nil) }
    let count = IOSurfaceGetBytesPerRow(surface) * IOSurfaceGetHeight(surface)
    let bytes = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
    return Array(UnsafeBufferPointer(start: bytes, count: count))
}

@Test
func contiguousCopyIncludesAlignedPadding() throws {
    let source = try #require(SurfaceCopy.makeSurface(width: 13, height: 4))
    let destination = try #require(SurfaceCopy.makeSurface(width: 13, height: 4))
    let stride = IOSurfaceGetBytesPerRow(source)
    try #require(stride > 13 * 4)
    fillSurface(source)
    fillSurface(destination, value: 0xEE)

    #expect(SurfaceCopy.copy(from: source, to: destination) == stride * 4)
    #expect(surfaceBytes(destination) == surfaceBytes(source))
}

@Test(arguments: [false, true])
func unequalStridesCopyOnlyTheNarrowerSpan(sourceIsWider: Bool) throws {
    let stride = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, 13 * 4)
    let sourceStride = sourceIsWider ? stride * 2 : stride
    let destinationStride = sourceIsWider ? stride : stride * 2
    let source = try surfaceWithStride(sourceStride)
    let destination = try surfaceWithStride(destinationStride)
    fillSurface(source)
    fillSurface(destination, value: 0xEE)
    let expectedSource = surfaceBytes(source)
    let rowBytes = min(sourceStride, destinationStride)

    #expect(SurfaceCopy.copy(from: source, to: destination) == rowBytes * 4)
    let result = surfaceBytes(destination)
    for row in 0..<4 {
        let copied = row * destinationStride..<(row * destinationStride + rowBytes)
        let origin = row * sourceStride..<(row * sourceStride + rowBytes)
        #expect(Array(result[copied]) == Array(expectedSource[origin]))
        let untouched = (row * destinationStride + rowBytes)..<((row + 1) * destinationStride)
        #expect(result[untouched].allSatisfy { $0 == 0xEE })
    }
}

@Test(arguments: [(3, 5), (5, 3)])
func equalStridesCopyOnlyTheMinimumHeight(sourceHeight: Int, destinationHeight: Int) throws {
    let source = try #require(SurfaceCopy.makeSurface(width: 13, height: sourceHeight))
    let destination = try #require(SurfaceCopy.makeSurface(width: 13, height: destinationHeight))
    fillSurface(source)
    fillSurface(destination, value: 0xEE)
    let count = IOSurfaceGetBytesPerRow(source) * min(sourceHeight, destinationHeight)

    #expect(SurfaceCopy.copy(from: source, to: destination) == count)
    let result = surfaceBytes(destination)
    #expect(Array(result.prefix(count)) == Array(surfaceBytes(source).prefix(count)))
    #expect(result.dropFirst(count).allSatisfy { $0 == 0xEE })
}

@Test(arguments: [
    (64, 64, 4, 256, 256, Optional(256)),
    (64, 64, 4, 255, 256, nil),
    (64, 64, 4, 256, 255, nil),
    (64, 128, 4, 256, 512, nil),
    (Int.max, Int.max, 2, Int.max, Int.max, nil),
    (64, 64, 0, 256, 256, nil)
])
func contiguousSpanRequiresMatchingStridesAndBothBounds(
    sourceStride: Int,
    destinationStride: Int,
    rows: Int,
    sourceAllocation: Int,
    destinationAllocation: Int,
    expected: Int?
) {
    #expect(SurfaceCopy.contiguousByteCount(
        sourceStride: sourceStride,
        destinationStride: destinationStride,
        rows: rows,
        sourceAllocationSize: sourceAllocation,
        destinationAllocationSize: destinationAllocation
    ) == expected)
}

@Test
func croppedCopyPreservesPaddingDespiteEqualStrides() throws {
    let source = try #require(SurfaceCopy.makeSurface(width: 13, height: 4))
    let destination = try #require(SurfaceCopy.makeSurface(width: 10, height: 3))
    let stride = IOSurfaceGetBytesPerRow(source)
    try #require(stride == IOSurfaceGetBytesPerRow(destination))
    fillSurface(source)
    fillSurface(destination, value: 0xEE)
    let expectedSource = surfaceBytes(source)

    #expect(SurfaceCopy.copy(from: source, to: destination, contentSize: (width: 10, height: 3)) == 120)
    let result = surfaceBytes(destination)
    for row in 0..<3 {
        let content = row * stride..<(row * stride + 40)
        #expect(Array(result[content]) == Array(expectedSource[content]))
        #expect(result[(row * stride + 40)..<((row + 1) * stride)].allSatisfy { $0 == 0xEE })
    }
}
