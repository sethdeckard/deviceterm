// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import Testing

// PaneLifecycle / PaneCloseMode live in DaemonProtocol so every process
// reads one definition. These tests pin their wire rawValues and prove
// the wire structs carrying a PaneLifecycle encode/decode it as the
// same rawValue string the daemon emits.

@Test
func paneLifecycleRawValues() {
    #expect(PaneLifecycle.booting.rawValue == "booting")
    #expect(PaneLifecycle.rendering.rawValue == "rendering")
    #expect(PaneLifecycle.shutdown.rawValue == "shutdown")
    #expect(PaneLifecycle.failed.rawValue == "failed")
}

@Test
func paneCloseModeRawValues() {
    #expect(PaneCloseMode.detach.rawValue == "detach")
    #expect(PaneCloseMode.shutdown.rawValue == "shutdown")
}

@Test
func stateChangedEventDecodesLifecycleFromWireString() throws {
    let json = Data(#"{"paneId":"p","state":"rendering"}"#.utf8)
    let event = try JSONDecoder().decode(StateChangedEvent.self, from: json)
    #expect(event.state == .rendering)
}

@Test
func stateChangedEventEncodesLifecycleAsString() throws {
    let event = StateChangedEvent(paneId: "p", state: .shutdown)
    let data = try JSONEncoder().encode(event)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(object?["state"] as? String == "shutdown")
}

@Test
func panesListEntryRoundTripsLifecycle() throws {
    let entry = PanesListEntry(paneId: "p", udid: "u", state: .booting, family: "watch")
    let data = try JSONEncoder().encode(entry)
    let restored = try JSONDecoder().decode(PanesListEntry.self, from: data)
    #expect(restored == entry)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(object?["state"] as? String == "booting")
}
