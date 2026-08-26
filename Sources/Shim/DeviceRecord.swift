// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One device row parsed out of a `simctl list` snapshot. Two
/// snapshots taken around the real `simctl` invocation are diffed to find the
/// device that actually transitioned.
struct DeviceRecord: Sendable {
    let udid: String
    let name: String
    let state: String
    let runtime: String
}
