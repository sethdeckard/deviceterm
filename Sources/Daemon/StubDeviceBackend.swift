// SPDX-License-Identifier: GPL-3.0-or-later
//
// StubDeviceBackend: a synthetic `DeviceBackend` that needs no
// hardware. It emits one blank IOSurface frame and reports the
// physical-device capability set, so the capability plumbing (wire →
// coordinator → client gating) and the device pane lifecycle can be
// exercised hermetically. Only tests construct it; production device
// panes run on the split-pipeline-backed backend.
//
// `@unchecked Sendable`: it holds only value state + a retained surface;
// like the other backends, only the `PaneCoordinator` actor touches it.

import CoreVideo
import DaemonProtocol
import Foundation
import IOSurface

// Several `DeviceBackend` witnesses here are `throws` (required by the
// protocol) but have non-throwing stub bodies; the unneeded-throws rule
// is a false positive across this type.
// swiftlint:disable unneeded_throws_rethrows
final class StubDeviceBackend: DeviceBackend, @unchecked Sendable {
    // This backend takes the protocol's throwing location defaults, so
    // it must not advertise location; see `withoutLocation`.
    let capabilities = DeviceBackendCapabilities.physicalDevice.withoutLocation

    private let pixelWidth: Int
    private let pixelHeight: Int
    /// Retained for the backend's lifetime so the surface it handed the
    /// coordinator stays valid (the coordinator's `RetainedSurface`
    /// wrapper bumps its own use-count, but we keep a CF-strong ref so
    /// the underlying buffer isn't released early).
    private var surface: IOSurfaceRef?

    init(pixelWidth: Int = 390, pixelHeight: Int = 844) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    func startFrames(
        onFrame: @escaping @Sendable (PublishedSurface) -> Void,
        onFatal: @escaping @Sendable (String) -> Void
    ) throws {
        let properties: [IOSurfacePropertyKey: Any] = [
            .width: pixelWidth,
            .height: pixelHeight,
            .bytesPerElement: 4,
            .pixelFormat: kCVPixelFormatType_32BGRA
        ]
        guard let created = IOSurfaceCreate(properties as CFDictionary) else {
            return
        }
        surface = created
        onFrame(PublishedSurface(owned: LeasedSurface(surface: RetainedSurface(created)), lease: nil))
    }

    func stopFrames() {
        surface = nil
    }

    func pixelDimensions() -> (Int?, Int?) { (pixelWidth, pixelHeight) }

    // No display to observe, so the pane keeps its last commanded
    // orientation.
    func startDisplayOrientation(
        onChange: @escaping @Sendable (Orientation) -> Void
    ) -> Bool { false }

    func stopDisplayOrientation() {}

    func currentDisplayOrientation() -> Orientation? { nil }

    // Supported input verbs no-op: the stub has no device to drive, but
    // the capability gate lets touch / button / rotate / keyboard reach
    // here, so they must succeed rather than fault.
    func tapDown(at point: CGPoint, generation: UInt64) throws {}

    func tapUp(at point: CGPoint, generation: UInt64) throws {}

    func twoFingerDown(f1 finger1: CGPoint, f2 finger2: CGPoint, generation: UInt64) throws {}

    func twoFingerUp(f1 finger1: CGPoint, f2 finger2: CGPoint, generation: UInt64) throws {}

    func pressHardwareButton(_ button: HardwareButton, generation: UInt64) throws {}

    // Gated off by `capabilities` (never reached through the coordinator); a
    // no-op performs nothing, so it reports `false`.
    // swiftlint:disable:next async_without_await
    func rotate(to orientation: Orientation, generation: UInt64) async throws -> Bool { false }

    func keyDown(hidUsage: UInt32, generation: UInt64) throws {}

    func keyUp(hidUsage: UInt32, generation: UInt64) throws {}

    // Unsupported verbs are gated off by `capabilities`, so these are
    // never reached; they fault defensively if the gate is ever bypassed.
    func rotateCrown(delta: Double, generation: UInt64) throws { throw DeviceBackendError.notActive }

    func accessibilityFrontmostTree() throws -> [String: Any] {
        throw DeviceBackendError.accessibilityUnavailable(message: "stub backend has no accessibility")
    }

    func accessibilityElement(at pixelPoint: CGPoint) throws -> [String: Any] {
        throw DeviceBackendError.accessibilityUnavailable(message: "stub backend has no accessibility")
    }

    func shutdownBackend() {
        surface = nil
    }
}
// swiftlint:enable unneeded_throws_rethrows
