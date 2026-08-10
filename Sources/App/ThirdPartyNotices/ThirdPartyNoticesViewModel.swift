// SPDX-License-Identifier: GPL-3.0-or-later
//
// ThirdPartyNoticesViewModel: load state for the Help > Third-Party
// Notices window. Reads the bundled THIRD_PARTY_NOTICES.md and parses it
// into `[MarkdownBlock]` via the pure `MarkdownDocument`. The view binds
// to `state`; no presentation state lives in the view or window
// controller.

import Foundation
import Observation

@MainActor
@Observable
final class ThirdPartyNoticesViewModel {
    enum State: Equatable {
        case loading
        case loaded([MarkdownBlock])
        case unavailable
    }

    private(set) var state: State = .loading

    /// Resolve + parse the bundled notices. `.unavailable` when the
    /// resource is missing (e.g. a raw `swift run` without the assembled
    /// `.app` bundle) so the window degrades to a short message rather
    /// than appearing broken.
    func load() {
        guard
            let url = Bundle.main.url(
                forResource: "THIRD_PARTY_NOTICES",
                withExtension: "md"
            ),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            state = .unavailable
            return
        }
        state = .loaded(MarkdownDocument.parse(text))
    }
}
