// SPDX-License-Identifier: GPL-3.0-or-later
/// Maps a normalised 0…1 touch coordinate onto the device's native touchscreen
/// range.
///
/// The `mainTouchscreen` report expects a uint16 where 0…65535 spans the display
/// (not device pixels; sending pixels lands every touch in the top-left).
/// Out-of-range input is clamped so an edge or bezel gesture can't wrap the
/// uint16.
enum TouchScale {
    static let nativeMaximum = 65_535.0

    static func native(_ normalized: Double) -> UInt16 {
        UInt16(max(0, min(nativeMaximum, normalized * nativeMaximum)))
    }
}
