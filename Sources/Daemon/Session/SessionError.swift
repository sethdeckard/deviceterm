// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

public enum SessionError: Error, Equatable, Sendable {
    case notFound(
        sessionId:
        UUID
        )
    case invalidCapability(
        sessionId:
        UUID
        )
    /// `ShortID.maxMintAttempts` tries all collided with live
    /// short_ids. Vanishingly improbable at this scale (32^6 ≈ 1B
    /// values, expected concurrent sessions in the tens), present so
    /// a buggy RNG or pathological saturation surfaces as a clean
    /// error rather than an infinite mint loop. Surfaced to the
    /// client as `serverError`.
    case shortIDExhausted
}
