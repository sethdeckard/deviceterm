// SPDX-License-Identifier: GPL-3.0-or-later
//
// CoreSimulatorDeviceReader: the daemon's off-executor device enumerator.
//
// CoreSimulator's device-set read is synchronous and can block while its
// service is busy. Running it directly in DeviceCoordinator would occupy a
// Swift cooperative-executor worker for the whole wait. This wrapper confines
// every read to one serial DispatchQueue and returns only Sendable snapshots.

import CoreSimulatorBridge
import Foundation

typealias CoreSimulatorDeviceReadResult = Result<[CSBDeviceInfo], CoreSimulatorDeviceReadFailure>

/// `@unchecked Sendable`: both stored properties are immutable, `readDevices`
/// is Sendable, and `queue` serializes every invocation of it.
final class CoreSimulatorDeviceReader: @unchecked Sendable {
    private let queue: DispatchQueue
    private let readDevices: @Sendable () throws -> [CSBDeviceInfo]

    init(
        queue: DispatchQueue = DispatchQueue(
            label: "com.deviceterm.daemon.coresimulator-devices",
            qos: .default
        ),
        readDevices: @escaping @Sendable () throws -> [CSBDeviceInfo] = {
            try SimDeviceHandle.allDevices()
        }
    ) {
        self.queue = queue
        self.readDevices = readDevices
    }

    func read() async -> CoreSimulatorDeviceReadResult {
        await withCheckedContinuation { continuation in
            queue.async { [readDevices] in
                do {
                    continuation.resume(returning: .success(try readDevices()))
                } catch {
                    continuation.resume(
                        returning: .failure(
                            CoreSimulatorDeviceReadFailure(message: String(describing: error))
                        )
                    )
                }
            }
        }
    }
}
