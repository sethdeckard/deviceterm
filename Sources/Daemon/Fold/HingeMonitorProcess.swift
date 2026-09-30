// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The reader `HingeMonitor` drives, behind a protocol so a test can supply
/// output and an exit without spawning anything.
///
/// Narrow on purpose: stream bytes, say when it ended, and stop on request.
///
/// No exit status, because nothing would branch on one. An exit is always
/// unexpected, since this reader does not exit on its own, and the monitor's
/// answer is the same either way: replace it while the pane still wants an
/// angle. The monitor logs the exit rather than inspecting it.
protocol HingeMonitorProcess: AnyObject, Sendable {
    /// Called with each chunk of output, as bytes.
    ///
    /// Bytes rather than a decoded string, because a chunk boundary can fall
    /// inside a multi-byte character. A reading line carries `•` and `°`, and
    /// decoding a half of either yields nil and takes the rest of the chunk
    /// with it. The monitor joins the bytes and decodes whole lines.
    func onOutput(_ handler: @escaping @Sendable (Data) -> Void)
    /// Called once when the reader ends, however it ended.
    func onExit(_ handler: @escaping @Sendable () -> Void)
    /// Stop the reader. Idempotent.
    func terminate()
}
