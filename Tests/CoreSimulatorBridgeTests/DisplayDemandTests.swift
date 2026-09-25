// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
import Foundation
import IOSurface
import Testing

/// An already-bound proxy, installed through the handle's Objective-C storage.
/// No private framework is loaded; every delivery below is synchronous.
private final class DisplayProxy: NSObject {
    typealias SurfaceCallback = @convention(block) (AnyObject?) -> Void
    typealias DamageCallback = @convention(block) (NSArray) -> Void
    var surfaceCallback: SurfaceCallback?
    var damageCallback: DamageCallback?
    var reads = 0
    var registrations = 0
    var removals = 0
    let surface: IOSurfaceRef

    @objc var framebufferSurface: AnyObject {
        reads += 1
        return surface
    }

    init(surface: IOSurfaceRef) { self.surface = surface }

    @objc(registerCallbackWithUUID:ioSurfaceChangeCallback:)
    func registerSurface(_ uuid: NSUUID, callback: @escaping SurfaceCallback) {
        registrations += 1
        surfaceCallback = callback
    }

    @objc(registerCallbackWithUUID:damageRectanglesCallback:)
    func registerDamage(_ uuid: NSUUID, callback: @escaping DamageCallback) {
        registrations += 1
        damageCallback = callback
    }

    @objc(unregisterIOSurfaceChangeCallbackWithUUID:)
    func unregisterSurface(_ uuid: NSUUID) {
        removals += 1
        surfaceCallback = nil
    }

    @objc(unregisterDamageRectanglesCallbackWithUUID:)
    func unregisterDamage(_ uuid: NSUUID) {
        removals += 1
        damageCallback = nil
    }
}

private final class DisplayDeliveryCounter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "test.display-deliveries")
    private var values: [Bool] = []
    var deliveries: [Bool] { queue.sync { values } }
    func receive(_ surface: IOSurfaceRef?) { queue.sync { values.append(surface != nil) } }
}

@Test
func damageInvalidationsAvoidReadsAndPauseFencesOldCallbacks() throws {
    let surface = try #require(IOSurfaceCreate([
        kIOSurfaceWidth: 4, kIOSurfaceHeight: 4, kIOSurfaceBytesPerElement: 4
    ] as CFDictionary))
    let proxy = DisplayProxy(surface: surface)
    let handle = SimDisplayHandle()
    handle.setValue(proxy, forKey: "renderable")
    handle.setValue(true, forKey: "running")
    handle.setValue(true, forKey: "framesPaused")
    handle.setValue(NSUUID(), forKey: "callbackUUID")
    let counter = DisplayDeliveryCounter()
    try handle.startInvalidations(callback: counter.receive)
    defer { handle.stop() }
    let damage = try #require(proxy.damageCallback)
    let dedicated = try #require(proxy.surfaceCallback)
    damage([])
    dedicated(surface)
    damage([])
    #expect(counter.deliveries == [false, false, true, false])
    #expect(proxy.reads == 0)
    #expect(handle.currentSurface() != nil)
    #expect(proxy.reads == 1)
    handle.pauseFrames()
    damage([])
    dedicated(surface)
    #expect(counter.deliveries.count == 4)
    #expect(proxy.removals == 2)
    #expect(handle.currentSurface() != nil)
    try handle.startInvalidations(callback: counter.receive)
    #expect(counter.deliveries.count == 5)
    damage([])
    dedicated(surface)
    #expect(counter.deliveries.count == 5)
    proxy.damageCallback?([])
    #expect(counter.deliveries.count == 6)
    #expect(proxy.registrations == 4)
}
