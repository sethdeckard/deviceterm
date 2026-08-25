// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct TabCapturePayload: Codable, Sendable, Equatable {
    /// Captured screen content with `"\n"` separating rows. May be
    /// empty when the surface is attached but has nothing rendered
    /// yet (a freshly-attached tab before the shell prompt
    /// arrives).
    public let text: String

    public init(text: String) { self.text = text }
}
