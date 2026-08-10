// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import CoreSimulatorBridge
@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

// Live accessibility tests: need a *booted* sim and drive the real AX
// server. Part of the deliberate `make test-live` track (see the
// CoreSimulatorLiveTests target in Package.swift), excluded from the
// default `make verify`. Because `make test-live` provisions a clean
// booted sim first, a missing one is a loud `#require` failure here, not
// a silent skip: running this track always runs these tests.
private let coreSimulatorAvailable: Bool = {
    CoreSimulatorLoader.probe().ok
}()

/// The sim's AX server isn't ready the instant `simctl bootstatus`
/// returns: the first `frontmostApplication` queries can briefly come
/// back nil while SpringBoard's accessibility server finishes coming up.
/// Poll a throwaway client until it answers so these tests are
/// deterministic rather than racing boot. Returns once AX responds;
/// gives up after ~15s and lets the test's own call fail loudly.
private func waitForAXServer(udid: String, tries: Int = 30, delay: TimeInterval = 0.5) throws {
    let probe = try SimAccessibility.client(forUDID: udid)
    for attempt in 0..<tries {
        if (try? probe.frontmostTree()) != nil { return }
        if attempt < tries - 1 { Thread.sleep(forTimeInterval: delay) }
    }
}

@Test
func frontmostTreeReturnsRecursiveDict() throws {
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim — run via `make test-live`"
    )
    try waitForAXServer(udid: booted.udid)
    let client = try SimAccessibility.client(forUDID: booted.udid)
    let tree = try client.frontmostTree()
    // Tree shape: a root dict with `role` and `frame` always present,
    // plus `children` (the assertion below pins what counts as a
    // healthy `children` value per device family).
    #expect(tree["role"] is String)
    #expect(tree["frame"] is [String: Any])
    #expect(tree["children"] is [Any])

    // Frame dict must have x/y/w/h numeric keys.
    let frame = try #require(tree["frame"] as? [String: Any])
    #expect(frame["x"] is NSNumber)
    #expect(frame["y"] is NSNumber)
    #expect(frame["w"] is NSNumber)
    #expect(frame["h"] is NSNumber)

    // Close the gap that previously masked the watchOS limitation
    // (`ax tree` returns `{"children": []}` while elements exist).
    // On non-watch sims the AX walk MUST yield at least one child
    // for the freshly-booted SpringBoard screen; an empty tree
    // here means the recursion regressed. On watchOS the bridge's
    // `accessibilityChildren` is empty by design (the known
    // limitation `AXTreeAnnotator` annotates with a note at the
    // daemon layer); accept that here, the annotator unit tests
    // cover the note-injection logic deterministically.
    let family = DeviceFamilyClassifier.classify(booted.deviceTypeIdentifier)
    let children = try #require(tree["children"] as? [Any])
    if family != .watch {
        #expect(
            !children.isEmpty,
            "non-watch sim returned empty AX tree children — likely a regression of bug #3"
        )
    }
}

@Test
func sweepYieldsAtLeastOneElementOnBootedSim() throws {
    // The watchOS workaround. Drives the bridge call pattern
    // the daemon uses (`AXSweep.gridPoints` + `pixelPoint` +
    // `elementAtPoint`) and confirms a freshly-booted sim yields
    // at least one element regardless of family. The bridge's
    // `accessibilityChildren` is empty on watchOS, but
    // `elementAtPoint` resolves real elements; sweep aggregates
    // those. The pixel-scaling step is the load-bearing piece:
    // dropping it means every grid point lands sub-pixel near
    // `(0,0)` and the sweep returns empty on every screen, the
    // very regression this test guards against.
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim — run via `make test-live`"
    )
    try waitForAXServer(udid: booted.udid)
    let client = try SimAccessibility.client(forUDID: booted.udid)
    let rootTree = try client.frontmostTree()
    let screen = try #require(
        AXSweep.screenSize(fromTree: rootTree),
        "frontmost tree missing or zero-sized root frame"
    )
    var seen = Set<String>()
    var unique: [[String: Any]] = []
    for normalized in AXSweep.gridPoints(step: AXSweep.defaultStep) {
        let pixel = AXSweep.pixelPoint(normalized: normalized, screen: screen)
        guard let element = try? client.elementAtPoint(pixel) else { continue }
        let key = AXSweep.dedupKey(element: element)
        if seen.insert(key).inserted { unique.append(element) }
    }
    // SpringBoard on every family must yield something at the
    // default density. If it doesn't, either the bridge regressed
    // or the AX server isn't yet ready (waitForAXServer should have
    // caught the latter).
    #expect(!unique.isEmpty)
}

@Test
func elementAtPointReturnsFlatDict() throws {
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim — run via `make test-live`"
    )
    try waitForAXServer(udid: booted.udid)
    let client = try SimAccessibility.client(forUDID: booted.udid)
    // The bridge takes pixel coords. Convert (0.5, 0.5), the
    // intended screen-center query, to pixel space using the
    // frontmost app's root frame, matching how the daemon's
    // `accessibilityElement` does it.
    let rootTree = try client.frontmostTree()
    let screen = try #require(AXSweep.screenSize(fromTree: rootTree))
    let center = AXSweep.pixelPoint(
        normalized: CGPoint(x: 0.5, y: 0.5),
        screen: screen
    )
    let element = try client.elementAtPoint(center)
    // Flat variant: same keys as the root of a tree, but no
    // `children` key (the point hit is a single element, not a tree).
    #expect(element["role"] is String)
    #expect(element["frame"] is [String: Any])
    #expect(element["children"] == nil)
}

@Test
func twoClientsCoexistWithoutClobberingEachOther() throws {
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim — run via `make test-live`"
    )
    try waitForAXServer(udid: booted.udid)
    // The bug this guards against: with a per-client delegate,
    // constructing a second SimAccessibility replaces
    // AXPTranslator.sharedInstance's bridgeTokenDelegate with the new
    // client's, and the first client's tree call then routes to the
    // second client's SimDevice through the shared singleton. One
    // shared delegate multiplexed by token avoids that; both clients
    // should successfully walk their own trees.
    let clientA = try SimAccessibility.client(forUDID: booted.udid)
    let clientB = try SimAccessibility.client(forUDID: booted.udid)
    // Each tree call should succeed independently. A regression would
    // surface as a hang (request routed to a stale device) or as an
    // empty tree.
    let treeA = try clientA.frontmostTree()
    let treeB = try clientB.frontmostTree()
    #expect(treeA["role"] is String)
    #expect(treeB["role"] is String)
}
