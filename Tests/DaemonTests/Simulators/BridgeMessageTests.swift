// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import Foundation
import Testing

// BridgeMessage.unwrap is the single chokepoint that decides what the
// CLI sees as a `pane.<op>: <message>` error. The contract pin here
// matters because regressing it would bury the bridge's high-quality
// hints back inside NSError boilerplate.

@Test
func unwrapsNSErrorToLocalizedDescription() {
    // Construct the exact shape the CoreSimulatorBridge .m files
    // raise: NSLocalizedDescriptionKey set to the agent-readable
    // hint. unwrap must return just that string, not the verbose
    // "Error Domain=… Code=N \"…\" UserInfo=…" form Swift's
    // String(describing:) / "\(error)" emit for NSError.
    let error = NSError(
        domain: "CoreSimulatorBridge.SimAccessibility",
        code: 75,
        userInfo: [
            NSLocalizedDescriptionKey:
                "No element at point: fullscreen modal, out of bounds, or no AX server?"
        ]
    )
    #expect(
        BridgeMessage.unwrap(error) ==
        "No element at point: fullscreen modal, out of bounds, or no AX server?"
    )
}

@Test
func unwrapDoesNotIncludeNSErrorBoilerplate() {
    // Explicit regression check: whatever unwrap returns must not
    // contain the "Domain=", "Code=", or "UserInfo=" tokens that
    // String(describing:) inserts on an NSError. (Belt and braces:
    // the test above pins the exact string, but if the description
    // ever needs a small reformat, this guard stays valid.)
    let error = NSError(
        domain: "CoreSimulatorBridge.SimHIDClient",
        code: 49,
        userInfo: [NSLocalizedDescriptionKey: "HID send did not complete within 1s"]
    )
    let unwrapped = BridgeMessage.unwrap(error)
    #expect(!unwrapped.contains("Domain="))
    #expect(!unwrapped.contains("UserInfo"))
    // The code may legitimately appear in some descriptions (no
    // bridge error embeds it, but don't pin a negative
    // assertion just in case a future hint mentions it).
}

@Test
func unwrapsBridgePinchOpToHint() {
    // Sanity check with a second-domain example mirroring the
    // SimDisplayHandle "is the device booted?" hint.
    let error = NSError(
        domain: "CoreSimulatorBridge.SimDisplayHandle",
        code: 21,
        userInfo: [NSLocalizedDescriptionKey: "device.io is nil; is the device booted?"]
    )
    #expect(BridgeMessage.unwrap(error) == "device.io is nil; is the device booted?")
}

private struct StubLocalizedError: LocalizedError {
    let errorDescription: String?
}

@Test
func unwrapsSwiftLocalizedErrorToErrorDescription() {
    // Non-NSError Swift errors that conform to LocalizedError get
    // bridged through NSError.localizedDescription so the value
    // hits the same code path. Pinning so a future bridge change
    // doesn't accidentally regress to the type's `String(describing:)`
    // representation.
    let error = StubLocalizedError(errorDescription: "encoder rejected the payload")
    #expect(BridgeMessage.unwrap(error) == "encoder rejected the payload")
}
