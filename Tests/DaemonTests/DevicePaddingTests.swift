// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import Foundation
import IOSurface
import Testing

// DevicePadding detects the real content rect inside a decoded physical-device
// frame (the encoder pads width to a macroblock boundary and VideoToolbox can
// over-allocate height, both filled pure-black on the right/bottom). These
// tests build synthetic padded BGRA surfaces and pin the detection + the
// cropping copy.

/// A BGRA surface of `width × height` with the top-left `contentWidth ×
/// contentHeight` rect filled opaque white and everything else pure black,
/// exactly the shape of a padded device frame.
private func makePaddedSurface(
    width: Int,
    height: Int,
    contentWidth: Int,
    contentHeight: Int
) throws -> IOSurfaceRef {
    let surface = try #require(SurfaceCopy.makeSurface(width: width, height: height))
    IOSurfaceLock(surface, [], nil)
    let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
    let base = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
    memset(base, 0, height * bytesPerRow)
    for pixelY in 0..<contentHeight {
        let row = base + pixelY * bytesPerRow
        for pixelX in 0..<contentWidth {
            let pixel = row + pixelX * 4
            pixel[0] = 0xFF; pixel[1] = 0xFF; pixel[2] = 0xFF; pixel[3] = 0xFF
        }
    }
    IOSurfaceUnlock(surface, [], nil)
    return surface
}

private func firstByte(_ surface: IOSurfaceRef) -> UInt8 {
    IOSurfaceLock(surface, .readOnly, nil)
    defer { IOSurfaceUnlock(surface, .readOnly, nil) }
    return IOSurfaceGetBaseAddress(surface).load(as: UInt8.self)
}

@Test
func detectsContentRectTrimmingRightAndBottomPadding() throws {
    // The live-measured iPhone 16 Pro shape: 1206×2624 content in a 1216×2656
    // surface (right pad 10, bottom pad 32).
    let surface = try makePaddedSurface(width: 1_216, height: 2_656, contentWidth: 1_206, contentHeight: 2_624)
    let size = DevicePadding.contentSize(of: surface)
    #expect(size?.width == 1_206)
    #expect(size?.height == 2_624)
}

@Test
func detectsContentWhenPaddingIsExactlyMaxTrim() throws {
    // Right/bottom padding exactly at the trim cap (64): the content edge sits at
    // width - maxTrim - 1, the last column/row the edge-band scan must still reach.
    // A band that stopped at width - maxTrim would miss it and wrongly return nil.
    let surface = try makePaddedSurface(width: 256, height: 256, contentWidth: 192, contentHeight: 192)
    let size = DevicePadding.contentSize(of: surface, maxTrim: 64)
    #expect(size?.width == 192)
    #expect(size?.height == 192)
}

@Test
func returnsFullSizeWithZeroMaxTrimWhenNoPadding() throws {
    // maxTrim: 0 must scan the final column/row, not an empty range.
    let surface = try makePaddedSurface(width: 48, height: 64, contentWidth: 48, contentHeight: 64)
    let size = DevicePadding.contentSize(of: surface, maxTrim: 0)
    #expect(size?.width == 48)
    #expect(size?.height == 64)
}

@Test
func returnsNilForFullyBlackFrame() throws {
    let surface = try makePaddedSurface(width: 64, height: 64, contentWidth: 0, contentHeight: 0)
    #expect(DevicePadding.contentSize(of: surface) == nil)
}

@Test
func returnsNilWhenPaddingExceedsTrimCap() throws {
    // Content far smaller than the surface ⇒ padding beyond the trim cap ⇒
    // untrusted (a too-dark frame), so detection declines rather than
    // over-cropping.
    let surface = try makePaddedSurface(width: 256, height: 256, contentWidth: 100, contentHeight: 100)
    #expect(DevicePadding.contentSize(of: surface, maxTrim: 64) == nil)
}

@Test
func returnsFullSizeWhenThereIsNoPadding() throws {
    let surface = try makePaddedSurface(width: 48, height: 64, contentWidth: 48, contentHeight: 64)
    let size = DevicePadding.contentSize(of: surface)
    #expect(size?.width == 48)
    #expect(size?.height == 64)
}

@Test
func surfaceCopyCropsToTheContentSize() throws {
    let source = try makePaddedSurface(width: 32, height: 40, contentWidth: 20, contentHeight: 28)
    let owned = try #require(SurfaceCopy.makeSurface(width: 20, height: 28))
    SurfaceCopy.copy(from: source, to: owned, contentSize: (width: 20, height: 28))
    #expect(IOSurfaceGetWidth(owned) == 20)
    #expect(IOSurfaceGetHeight(owned) == 28)
    // Top-left content (white) is preserved through the crop.
    #expect(firstByte(owned) == 0xFF)
}

@Test
func surfaceCopyWithoutContentSizeKeepsFullSurface() throws {
    let source = try makePaddedSurface(width: 32, height: 40, contentWidth: 32, contentHeight: 40)
    let owned = try #require(SurfaceCopy.makeSurface(width: 32, height: 40))
    SurfaceCopy.copy(from: source, to: owned, contentSize: nil)
    #expect(IOSurfaceGetWidth(owned) == 32)
    #expect(IOSurfaceGetHeight(owned) == 40)
}
