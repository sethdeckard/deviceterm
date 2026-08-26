// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// The device-control menu-bar
/// fallbacks, split out of the layout controller's hot file. These are
/// the responder-chain forwarders the main menu targets when no pane VC
/// is first responder: each routes to the tab's targeted sim pane
/// (`targetedSimPane()`, which lives on the controller since the
/// size-preset selectors and menu validation share it). Enablement is
/// gated in the controller's `validateUserInterfaceItem`.
extension PaneLayoutViewController {
    @objc
    func pressHardwareHome(_ sender: Any?) { targetedSimPane()?.pressHardwareHome(sender) }
    @objc
    func invokeAppSwitcher(_ sender: Any?) { targetedSimPane()?.invokeAppSwitcher(sender) }
    @objc
    func pressHardwareLock(_ sender: Any?) { targetedSimPane()?.pressHardwareLock(sender) }
    @objc
    func pressHardwareSide(_ sender: Any?) { targetedSimPane()?.pressHardwareSide(sender) }
    @objc
    func pressHardwareSiri(_ sender: Any?) { targetedSimPane()?.pressHardwareSiri(sender) }
    @objc
    func pressHardwareApplePay(_ sender: Any?) {
        targetedSimPane()?.pressHardwareApplePay(sender)
    }
    @objc
    func rotateDeviceLeft(_ sender: Any?) { targetedSimPane()?.rotateDeviceLeft(sender) }
    @objc
    func rotateDeviceRight(_ sender: Any?) { targetedSimPane()?.rotateDeviceRight(sender) }
    @objc
    func applySimulatedLocation(_ sender: Any?) {
        targetedSimPane()?.applySimulatedLocation(sender)
    }
    @objc
    func applyRouteFile(_ sender: Any?) {
        targetedSimPane()?.applyRouteFile(sender)
    }
    @objc
    func useMyLocation(_ sender: Any?) {
        targetedSimPane()?.useMyLocation(sender)
    }
    @objc
    func showCustomCoordinates(_ sender: Any?) {
        targetedSimPane()?.showCustomCoordinates(sender)
    }
    @objc
    func rebootDevice(_ sender: Any?) { targetedSimPane()?.rebootDevice(sender) }
    @objc
    func eraseAllContent(_ sender: Any?) { targetedSimPane()?.eraseAllContent(sender) }
    @objc
    func screenshotPane(_ sender: Any?) { targetedSimPane()?.screenshotPane(sender) }
    @objc
    func recordPane(_ sender: Any?) { targetedSimPane()?.recordPane(sender) }
    @objc
    func openInSimulatorApp(_ sender: Any?) { targetedSimPane()?.openInSimulatorApp(sender) }
    @objc
    func revealInFinder(_ sender: Any?) { targetedSimPane()?.revealInFinder(sender) }
    @objc
    func shutDownSim(_ sender: Any?) { targetedSimPane()?.shutDownSim(sender) }
    @objc
    func installApp(_ sender: Any?) { targetedSimPane()?.installApp(sender) }
    @objc
    func pressDigitalCrown(_ sender: Any?) { targetedSimPane()?.pressDigitalCrown(sender) }
    @objc
    func rotateCrownUp(_ sender: Any?) { targetedSimPane()?.rotateCrownUp(sender) }
    @objc
    func rotateCrownDown(_ sender: Any?) { targetedSimPane()?.rotateCrownDown(sender) }
}
