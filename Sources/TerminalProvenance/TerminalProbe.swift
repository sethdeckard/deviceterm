// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Injectable seam that turns a foreground pid and tty name into verified
/// `TerminalAnchorFacts`. Production wires `defaultTerminalProbe` (the real
/// syscall path in `DefaultTerminalProbe`); tests inject synthetic facts so
/// anchor binding can be exercised without real terminals.
///
/// This module has no non-Darwin probe implementation, so the production
/// binding fails closed there.
public typealias TerminalProbe = @Sendable (_ foregroundPid: pid_t, _ ttyName: String)
    -> TerminalAnchorFacts?

#if canImport(Darwin)
public let defaultTerminalProbe: TerminalProbe = {
    DefaultTerminalProbe.derive(foregroundPid: $0, ttyName: $1)
}
#else
public let defaultTerminalProbe: TerminalProbe = { _, _ in nil }
#endif
