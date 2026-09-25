// SPDX-License-Identifier: GPL-3.0-or-later

/// Background windows still consume frames; minimized and hidden ones do not.
enum SimulatorFrameDemandDecision {
    static func isWindowEligible(visible: Bool, minimized: Bool, applicationHidden: Bool) -> Bool {
        visible && !minimized && !applicationHidden
    }
}
