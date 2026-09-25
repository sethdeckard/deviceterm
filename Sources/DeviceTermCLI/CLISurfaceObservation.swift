// SPDX-License-Identifier: GPL-3.0-or-later

/// A live frame subscription held for one surface wait. Closing it releases
/// capture demand; losing it must fail the wait rather than report stillness.
protocol CLISurfaceObservation: AnyObject {
    func latestSequence() throws -> UInt64?
    func close()
}
