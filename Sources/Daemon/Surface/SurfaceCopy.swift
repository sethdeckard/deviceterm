// SPDX-License-Identifier: GPL-3.0-or-later
//
// SurfaceCopy: allocation and copy primitives for daemon-owned
// IOSurfaces.
//
// A decoded device frame is copied into a daemon-owned surface (a
// `LeasedSurfacePool` slot) before it reaches subscribers, isolating them
// from VideoToolbox's decode pool: VT recycles its decode surfaces on its
// own schedule, so shipping one directly would let it overwrite pixels a
// subscriber is still sampling. These are the pure allocation/copy
// building blocks the pool and the device backend compose; the ownership
// and reuse protocol lives in `LeasedSurfacePool`.

import CoreVideo
import Foundation
import IOSurface

enum SurfaceCopy {
    /// Allocate one BGRA IOSurface sized for the device display.
    static func makeSurface(width: Int, height: Int) -> IOSurfaceRef? {
        let bytesPerRow = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * 4)
        let properties: [IOSurfacePropertyKey: Any] = [
            .width: width,
            .height: height,
            .bytesPerElement: 4,
            .bytesPerRow: bytesPerRow,
            .pixelFormat: kCVPixelFormatType_32BGRA
        ]
        return IOSurfaceCreate(properties as CFDictionary)
    }

    /// Lock both surfaces and copy row-by-row (source and destination may
    /// have different row strides), so the owned copy is a faithful
    /// snapshot.
    static func copy(from source: IOSurfaceRef, to destination: IOSurfaceRef) {
        IOSurfaceLock(source, .readOnly, nil)
        IOSurfaceLock(destination, [], nil)
        defer {
            IOSurfaceUnlock(destination, [], nil)
            IOSurfaceUnlock(source, .readOnly, nil)
        }
        let sourceBase = IOSurfaceGetBaseAddress(source)
        let destinationBase = IOSurfaceGetBaseAddress(destination)
        let sourceStride = IOSurfaceGetBytesPerRow(source)
        let destinationStride = IOSurfaceGetBytesPerRow(destination)
        let rowBytes = min(sourceStride, destinationStride)
        let rows = min(IOSurfaceGetHeight(source), IOSurfaceGetHeight(destination))
        for row in 0..<rows {
            memcpy(
                destinationBase + row * destinationStride,
                sourceBase + row * sourceStride,
                rowBytes
            )
        }
    }

    /// Copy the top-left `contentWidth × contentHeight` rect of `source`
    /// into a destination of that exact size, cropping the right/bottom
    /// padding the encoder / VideoToolbox add to a device frame. Unlike the
    /// stride-tolerant `copy`, the per-row span is exactly `contentWidth × 4`
    /// The destination's aligned stride would otherwise pad back up to the
    /// source width and re-include the padding columns.
    static func copyCropped(
        from source: IOSurfaceRef,
        to destination: IOSurfaceRef,
        contentWidth: Int,
        contentHeight: Int
    ) {
        IOSurfaceLock(source, .readOnly, nil)
        IOSurfaceLock(destination, [], nil)
        defer {
            IOSurfaceUnlock(destination, [], nil)
            IOSurfaceUnlock(source, .readOnly, nil)
        }
        let sourceBase = IOSurfaceGetBaseAddress(source)
        let destinationBase = IOSurfaceGetBaseAddress(destination)
        let sourceStride = IOSurfaceGetBytesPerRow(source)
        let destinationStride = IOSurfaceGetBytesPerRow(destination)
        let rowBytes = min(contentWidth * 4, min(sourceStride, destinationStride))
        let rows = min(contentHeight, min(IOSurfaceGetHeight(source), IOSurfaceGetHeight(destination)))
        for row in 0..<rows {
            memcpy(
                destinationBase + row * destinationStride,
                sourceBase + row * sourceStride,
                rowBytes
            )
        }
    }

    /// Copy `source` into `destination`, cropping to `contentSize` when it
    /// is smaller than the source in either dimension, else a full copy.
    /// `destination` must already be sized to the content rect.
    static func copy(
        from source: IOSurfaceRef,
        to destination: IOSurfaceRef,
        contentSize: (width: Int, height: Int)?
    ) {
        let sourceWidth = IOSurfaceGetWidth(source)
        let sourceHeight = IOSurfaceGetHeight(source)
        let targetWidth = min(contentSize?.width ?? sourceWidth, sourceWidth)
        let targetHeight = min(contentSize?.height ?? sourceHeight, sourceHeight)
        if targetWidth == sourceWidth, targetHeight == sourceHeight {
            copy(from: source, to: destination)
        } else {
            copyCropped(from: source, to: destination, contentWidth: targetWidth, contentHeight: targetHeight)
        }
    }

    /// The content-cropped destination dimensions for a source surface.
    static func contentDimensions(
        source: IOSurfaceRef,
        contentSize: (width: Int, height: Int)?
    ) -> (width: Int, height: Int) {
        let sourceWidth = IOSurfaceGetWidth(source)
        let sourceHeight = IOSurfaceGetHeight(source)
        return (
            min(contentSize?.width ?? sourceWidth, sourceWidth),
            min(contentSize?.height ?? sourceHeight, sourceHeight)
        )
    }
}
