// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import IOSurface
import Testing

// The copy reports what it moved so a bandwidth measurement doesn't have to
// re-derive it. The two branches move different amounts for the same content
// rect, which is the whole reason the figure comes from the copy: an uncropped
// copy spans the full row stride, alignment padding included, while a cropped
// one narrows each row to the content width.

@Test("an uncropped copy reports the full stride it spans, not the visible pixels")
func uncroppedCopyReportsStrideSpan() throws {
    // A width whose natural row size (13 x 4 = 52 bytes) aligns up, so stride
    // padding exists to be counted.
    let source = try #require(SurfaceCopy.makeSurface(width: 13, height: 4))
    let destination = try #require(SurfaceCopy.makeSurface(width: 13, height: 4))
    let stride = IOSurfaceGetBytesPerRow(source)
    try #require(stride > 13 * 4)

    let moved = SurfaceCopy.copy(from: source, to: destination, contentSize: nil)
    #expect(moved == stride * 4)
    #expect(moved > 13 * 4 * 4)
}

@Test("a cropped copy reports only the content rect it narrows each row to")
func croppedCopyReportsContentSpan() throws {
    let source = try #require(SurfaceCopy.makeSurface(width: 13, height: 4))
    let destination = try #require(SurfaceCopy.makeSurface(width: 10, height: 3))

    let moved = SurfaceCopy.copy(from: source, to: destination, contentSize: (width: 10, height: 3))
    #expect(moved == 10 * 4 * 3)
}

@Test("a content rect equal to the source takes the uncropped branch")
func fullSizeContentRectMatchesTheUncroppedCount() throws {
    let source = try #require(SurfaceCopy.makeSurface(width: 13, height: 4))
    let destination = try #require(SurfaceCopy.makeSurface(width: 13, height: 4))

    let explicit = SurfaceCopy.copy(from: source, to: destination, contentSize: (width: 13, height: 4))
    let implicit = SurfaceCopy.copy(from: source, to: destination, contentSize: nil)
    #expect(explicit == implicit)
}
