// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct WindowInfoPayload: Codable, Sendable, Equatable {
    public let index: Int
    public let isKey: Bool
    public let tabCount: Int
    public let selectedTabShortId: String?

    public init(
        index: Int,
        isKey: Bool,
        tabCount: Int,
        selectedTabShortId: String?
    ) {
        self.index = index
        self.isKey = isKey
        self.tabCount = tabCount
        self.selectedTabShortId = selectedTabShortId
    }
}
