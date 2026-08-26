// SPDX-License-Identifier: GPL-3.0-or-later

import ApplicationServices
import CoreGraphics

/// This process's privacy grants.
///
/// Both grants attribute to the process that calls the API, which is why
/// they are read (and requested) inside the resident harness rather than
/// in the short-lived client. A bare binary launched from a terminal
/// attributes to the terminal app; the bundled harness attributes to
/// itself. That difference is the entire reason the harness is bundled.
enum TCCStatus {
    /// Screen Recording. Required by ScreenCaptureKit. Preflight never
    /// prompts, so `doctor` can report status without side effects.
    static var hasScreenRecording: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Accessibility. Required to read another app's AX tree and to post
    /// synthetic events into it.
    static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    /// Surface the system prompt for each missing grant.
    ///
    /// This is also what *registers* the process in the System Settings
    /// lists: an app that never asks never appears there, so there'd be
    /// nothing for the user to tick. Already-granted permissions are left
    /// alone, so this is a no-op on a healthy machine.
    static func requestMissingGrants() {
        if !hasScreenRecording {
            _ = CGRequestScreenCaptureAccess()
        }
        if !hasAccessibility {
            // The SDK vends `kAXTrustedCheckOptionPrompt` as a C global
            // `var`, which Swift 6 rejects as shared mutable state. Its
            // documented value is this literal.
            let promptKey = "AXTrustedCheckOptionPrompt" as CFString
            let options = [promptKey: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    }
}
