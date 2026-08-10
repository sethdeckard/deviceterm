// SPDX-License-Identifier: GPL-3.0-or-later

import ChannelBootstrap

/// The host-registered virtual keyboard's lifecycle: lazy registration, the
/// delta-less pressed set, and rebuild-then-replay recovery on a failed report.
///
/// The device's keyboard report is delta-less, since every send carries the
/// *full* pressed set, so this keeps the set and resends it on each change,
/// which is what shift-plus-letter text needs. Registration is lazy (on the
/// first key, over the keyboard's own channel) so a pane the user only taps
/// never hides the device's on-screen keyboard.
///
/// `@unchecked Sendable`: it is confined to the relay's keyboard pump, whose
/// serial worker is the only caller that touches its mutable state. The one
/// exception is `close()` from the relay's `deinit`, which runs only after
/// every submitted job has completed.
final class VirtualKeyboard: @unchecked Sendable {
    private let channels: DeviceChannels
    private let diagnostics: (@Sendable (String) -> Void)?
    private var channel: DeviceChannel?
    private var serviceID: UInt64?
    private var pressed: Set<UInt16> = []

    init(channels: DeviceChannels, diagnostics: (@Sendable (String) -> Void)?) {
        self.channels = channels
        self.diagnostics = diagnostics
    }

    func press(_ usage: UInt16) async {
        pressed.insert(usage)
        await flush()
    }

    func release(_ usage: UInt16) async {
        pressed.remove(usage)
        await flush()
    }

    /// Close the keyboard's channel; called at relay teardown.
    func close() {
        channel?.close()
    }

    /// Send the current pressed set. On a delivery failure, rebuild the virtual
    /// keyboard on a fresh channel and replay once; only this channel is
    /// discarded, so the touchscreen channel and active mirror stay intact.
    private func flush() async {
        do {
            try await send()
        } catch {
            discard()
            diagnostics?("keyboard HID delivery failed; rebuilding virtual keyboard")
            do {
                try await send()
            } catch {
                discard()
                diagnostics?("keyboard HID unavailable; next input will retry")
            }
        }
    }

    private func send() async throws {
        if channel == nil {
            let fresh = try await channels.open(.humanInput)
            let registered = try await register(on: fresh)
            // Begin each registration with an explicit all-keys-up report so a
            // failed predecessor can't leave the replacement holding stale keys.
            try await fresh.emit(HIDReports.sendReport(
                HIDReports.keyboardReport(usages: [], timestamp: HIDReports.machTicks()),
                to: registered
            ))
            channel = fresh
            serviceID = registered
        }
        guard let channel, let serviceID else { return }
        try await channel.emit(HIDReports.sendReport(
            HIDReports.keyboardReport(usages: pressed, timestamp: HIDReports.machTicks()),
            to: serviceID
        ))
    }

    private func register(on channel: DeviceChannel) async throws -> UInt64 {
        let reply = try await channel.request(HIDReports.createKeyboard(serviceID: HIDReports.keyboardServiceID))
        return reply.firstValue(under: "serviceID")?.unsigned ?? HIDReports.keyboardServiceID
    }

    private func discard() {
        channel?.close()
        channel = nil
        serviceID = nil
    }
}
