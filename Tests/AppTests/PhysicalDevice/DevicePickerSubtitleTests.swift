// SPDX-License-Identifier: GPL-3.0-or-later
//
// DevicePickerView.subtitle: the pure row-subtitle composer. Joins the
// known model + iOS version (so two devices that share a name read
// distinctly) and surfaces the unavailable reason for disabled rows.

@testable import App
import DaemonProtocol
import Testing

@MainActor
struct DevicePickerSubtitleTests {
    private func entry(
        name: String? = "enceladus",
        model: String? = nil,
        osVersion: String? = nil,
        available: Bool = true,
        reason: String? = nil
    ) -> PhysicalDeviceListEntry {
        PhysicalDeviceListEntry(
            deviceId: "d",
            name: name,
            model: model,
            osVersion: osVersion,
            available: available,
            unavailableReason: reason
        )
    }

    @Test
    func joinsModelAndOS() {
        #expect(
            DevicePickerView.subtitle(for: entry(model: "iPhone 15 Pro", osVersion: "17.5"))
                == "iPhone 15 Pro · iOS 17.5"
        )
    }

    @Test
    func modelOnly() {
        #expect(
            DevicePickerView.subtitle(for: entry(model: "iPhone 16")) == "iPhone 16"
        )
    }

    @Test
    func osOnly() {
        #expect(
            DevicePickerView.subtitle(for: entry(osVersion: "18.1")) == "iOS 18.1"
        )
    }

    @Test
    func neitherIsNil() {
        #expect(DevicePickerView.subtitle(for: entry()) == nil)
    }

    @Test
    func omitsModelWhenItIsTheTitle() {
        // name nil → the row title falls back to model, so the subtitle
        // must not repeat it (only the OS version remains).
        #expect(
            DevicePickerView.subtitle(
                for: entry(name: nil, model: "iPhone 15 Pro", osVersion: "17.5")
            ) == "iOS 17.5"
        )
    }

    @Test
    func nilWhenModelIsTitleAndNoOS() {
        // name nil, model is the title, no OS → nothing left for the
        // subtitle.
        #expect(
            DevicePickerView.subtitle(for: entry(name: nil, model: "iPhone 15 Pro"))
                == nil
        )
    }

    @Test
    func unavailableShowsReasonOverModelAndOS() {
        let subtitle = DevicePickerView.subtitle(
            for: entry(
                model: "iPhone 15 Pro",
                osVersion: "17.5",
                available: false,
                reason: "needs a newer iOS"
            )
        )
        #expect(subtitle == "needs a newer iOS")
    }
}
