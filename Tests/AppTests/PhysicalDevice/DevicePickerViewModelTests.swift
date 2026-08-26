// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Testing

/// The Mirror Physical Device… picker's
/// presentation logic against the fake daemon: loading the roster,
/// surfacing a load error, the display-name composition, and that only
/// an available pick fires the attach callback.
@MainActor
struct DevicePickerViewModelTests {
    private enum PickerError: Error { case listFailed }

    private func makeViewModel(
        fake: FakeDaemonClient,
        onAttach: @escaping (String, String?) -> Void = { _, _ in },
        onDismiss: @escaping () -> Void = {}
    ) -> DevicePickerViewModel {
        DevicePickerViewModel(daemon: fake, attach: onAttach, dismiss: onDismiss)
    }

    @Test
    func loadPopulatesDevices() async {
        let fake = FakeDaemonClient()
        fake.physicalDeviceListResult = [
            PhysicalDeviceListEntry(deviceId: "fd00::1", name: "iPhone 16 Pro", model: "iPhone17,1")
        ]
        let viewModel = makeViewModel(fake: fake)
        await viewModel.load()
        #expect(viewModel.devices.map(\.deviceId) == ["fd00::1"])
        #expect(viewModel.isLoading == false)
        #expect(viewModel.loadError == nil)
        #expect(fake.physicalDeviceListCallCount == 1)
    }

    @Test
    func loadSurfacesErrorAndClearsDevices() async {
        let fake = FakeDaemonClient()
        fake.physicalDeviceListResult = [PhysicalDeviceListEntry(deviceId: "fd00::1")]
        fake.physicalDeviceListError = PickerError.listFailed
        let viewModel = makeViewModel(fake: fake)
        await viewModel.load()
        #expect(viewModel.devices.isEmpty)
        #expect(viewModel.loadError != nil)
        #expect(viewModel.isLoading == false)
    }

    @Test
    func selectAttachesAvailableDeviceAndDismisses() {
        let fake = FakeDaemonClient()
        var attached: (deviceId: String, displayName: String?)?
        var dismissed = false
        let viewModel = makeViewModel(
            fake: fake,
            onAttach: { attached = ($0, $1) },
            onDismiss: { dismissed = true }
        )
        let entry = PhysicalDeviceListEntry(deviceId: "fd00::1", name: "iPhone 16 Pro")
        viewModel.select(entry)
        #expect(attached?.deviceId == "fd00::1")
        #expect(attached?.displayName == "iPhone 16 Pro")
        #expect(dismissed)
    }

    @Test
    func selectComposesDisplayNameFromModelWhenNameMissing() {
        let fake = FakeDaemonClient()
        var attached: (deviceId: String, displayName: String?)?
        let viewModel = makeViewModel(fake: fake, onAttach: { attached = ($0, $1) })
        viewModel.select(PhysicalDeviceListEntry(deviceId: "fd00::2", model: "iPad13,4"))
        #expect(attached?.displayName == "iPad13,4")
    }

    @Test
    func selectPassesNilDisplayNameWhenNameAndModelMissing() {
        let fake = FakeDaemonClient()
        var attached: (deviceId: String, displayName: String?)?
        let viewModel = makeViewModel(fake: fake, onAttach: { attached = ($0, $1) })
        viewModel.select(PhysicalDeviceListEntry(deviceId: "fd00::3"))
        #expect(attached?.deviceId == "fd00::3")
        #expect(attached?.displayName == nil)
    }

    @Test
    func selectIgnoresUnavailableDevice() {
        let fake = FakeDaemonClient()
        var attachCount = 0
        var dismissed = false
        let viewModel = makeViewModel(
            fake: fake,
            onAttach: { _, _ in attachCount += 1 },
            onDismiss: { dismissed = true }
        )
        let entry = PhysicalDeviceListEntry(
            deviceId: "fd00::4",
            name: "iPhone",
            available: false,
            unavailableReason: "iOS too old"
        )
        viewModel.select(entry)
        #expect(attachCount == 0)
        #expect(dismissed == false)
    }

    @Test
    func cancelDismisses() {
        let fake = FakeDaemonClient()
        var dismissed = false
        let viewModel = makeViewModel(fake: fake, onDismiss: { dismissed = true })
        viewModel.cancel()
        #expect(dismissed)
    }
}
