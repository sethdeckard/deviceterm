// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Testing

@MainActor
@Suite
struct UpdateViewModelTests {
    private func available(_ version: String = "1", notes: String? = nil) -> UpdateViewModel.State {
        .updateAvailable(version: version, notes: notes, install: {}, dismiss: {})
    }

    @Test
    func idleIsNotVisible() {
        let model = UpdateViewModel()
        #expect(model.isVisible == false)
        model.set(.checking(cancel: {}))
        #expect(model.isVisible == true)
        model.reset()
        #expect(model.isVisible == false)
    }

    @Test
    func titlesReflectState() {
        #expect(UpdateViewModel.State.checking(cancel: {}).title == "Checking for Updates…")
        #expect(
            UpdateViewModel.State.updateAvailable(version: "0.2.0", notes: nil, install: {}, dismiss: {}).title
                == "Update Available: 0.2.0"
        )
        #expect(UpdateViewModel.State.downloading(fraction: 0.42, cancel: {}).title == "Downloading 42%")
        #expect(UpdateViewModel.State.extracting(fraction: 0.5).title == "Preparing 50%")
        #expect(UpdateViewModel.State.notFound(dismiss: {}).title == "No Updates Available")
        #expect(UpdateViewModel.State.error(message: "x", dismiss: {}).title == "Update Failed")
    }

    @Test
    func tintsAreSemantic() {
        // Accent only where there's something to act on; passive states neutral/positive.
        #expect(UpdateViewModel.State.checking(cancel: {}).tint == .neutral)
        #expect(available().tint == .accent)
        #expect(UpdateViewModel.State.readyToInstall(install: {}).tint == .accent)
        #expect(UpdateViewModel.State.notFound(dismiss: {}).tint == .positive)
        #expect(UpdateViewModel.State.error(message: "x", dismiss: {}).tint == .negative)
    }

    @Test
    func onlyPassiveStatesAutoDismiss() {
        #expect(UpdateViewModel.State.notFound(dismiss: {}).autoDismisses == true)
        #expect(UpdateViewModel.State.error(message: "x", dismiss: {}).autoDismisses == true)
        #expect(UpdateViewModel.State.checking(cancel: {}).autoDismisses == false)
        #expect(available().autoDismisses == false)
    }

    @Test
    func primaryActionsOnlyOnActionableStates() {
        #expect(available().primaryAction?.label == "Update")
        #expect(UpdateViewModel.State.readyToInstall(install: {}).primaryAction?.label == "Restart")
        #expect(UpdateViewModel.State.notFound(dismiss: {}).primaryAction == nil)
        #expect(UpdateViewModel.State.checking(cancel: {}).primaryAction == nil)
    }

    @Test
    func updateDetailsCarryVersionAndNotes() {
        let state = UpdateViewModel.State.updateAvailable(
            version: "0.2.0",
            notes: "<b>hi</b>",
            install: {},
            dismiss: {}
        )
        #expect(state.updateDetails?.version == "0.2.0")
        #expect(state.updateDetails?.notes == "<b>hi</b>")
        // Non-update states carry no details.
        #expect(UpdateViewModel.State.checking(cancel: {}).updateDetails == nil)
    }

    @Test
    func renderNotesHandlesHTMLEmptyAndNil() {
        // HTML renders to non-empty text.
        let rendered = UpdatePopoverView.renderNotes("<h3>New</h3><p>Faster.</p>")
        let text = rendered.map { String($0.characters) }
        #expect(text?.contains("Faster") == true)
        // Empty / whitespace / nil → nil so the view shows a placeholder.
        #expect(UpdatePopoverView.renderNotes(nil) == nil)
        #expect(UpdatePopoverView.renderNotes("   ") == nil)
    }

    @Test
    func simulatorCoversEveryVisibleState() {
        // Guards that the debug simulator lists one of each pill state.
        let titles = Set(UpdateSimulator.sampleStates().map(\.title))
        #expect(titles.count == UpdateSimulator.sampleStates().count)
        #expect(titles.contains("No Updates Available"))
        #expect(titles.contains("Restart to Complete Update"))
    }
}
