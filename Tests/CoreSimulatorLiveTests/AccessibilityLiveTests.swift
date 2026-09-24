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

    // An unchecked empty tree masks the watchOS limitation (`ax tree`
    // returns `{"children": []}` while elements exist), so the two
    // families are asserted apart.
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
    // the daemon uses (`AXSweep.gridPoints` + `nativePixel` +
    // `elementAtPoint`) and confirms a freshly-booted sim yields
    // at least one element regardless of family. The bridge's
    // `accessibilityChildren` is empty on watchOS, but
    // `elementAtPoint` resolves real elements; sweep aggregates
    // those. The scaling step is what this guards: drop it and
    // every grid point lands sub-pixel near `(0,0)`, so the sweep
    // returns empty on every screen.
    //
    // The track boots its own sim for a clean slate, so the device
    // is portrait and `nativePixel` is the identity beyond scaling.
    // Rotated mapping is covered in `AXSweepTests`, which needs no
    // sim.
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
    let interface = try #require(
        AXSweep.interfaceSize(fromTree: rootTree),
        "frontmost tree missing or zero-sized root frame"
    )
    var seen = Set<String>()
    var unique: [[String: Any]] = []
    for displayed in AXSweep.gridPoints(step: AXSweep.defaultStep) {
        let pixel = AXSweep.nativePixel(
            displayed: displayed,
            orientation: .portrait,
            interface: interface
        )
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
    // The bridge takes panel coords. Convert (0.5, 0.5), the
    // intended screen-center query, through the frontmost app's
    // root frame, matching how the daemon's `accessibilityElement`
    // does it. The track's own sim is portrait.
    let rootTree = try client.frontmostTree()
    let interface = try #require(AXSweep.interfaceSize(fromTree: rootTree))
    let center = AXSweep.nativePixel(
        displayed: CGPoint(x: 0.5, y: 0.5),
        orientation: .portrait,
        interface: interface
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

/// Every positive-size frame in the tree, containers included, as candidate
/// hit-test locations. Taking them from the tree rather than naming a fixed
/// point keeps the probe on coordinates the tree itself reports.
private func framedNodes(_ node: [String: Any], into out: inout [(String, CGRect)]) {
    let role = node["role"] as? String ?? "?"
    let label = node["label"] as? String ?? node["identifier"] as? String ?? ""
    if let frame = node["frame"] as? [String: Any],
        let originX = frame["x"] as? Double, let originY = frame["y"] as? Double,
        let width = frame["w"] as? Double, let height = frame["h"] as? Double,
        width > 0, height > 0 {
        out.append((
            "\(role)|\(label)",
            CGRect(x: originX, y: originY, width: width, height: height)
        ))
    }
    for child in node["children"] as? [[String: Any]] ?? [] { framedNodes(child, into: &out) }
}

/// Try up to 15 pairs of reads a second apart for two whose role, label and
/// frame signatures match, and return the second of that pair. Frames caught
/// mid-animation name a place the element has since left, so a hit-test
/// against them misses for reasons that have nothing to do with the display
/// being asked. Returns nil if no pair matches, including when the reads
/// themselves fail.
private func settledTree(_ accessibility: SimAccessibility) -> [String: Any]? {
    func signature(_ tree: [String: Any]) -> String {
        var rows: [(String, CGRect)] = []
        framedNodes(tree, into: &rows)
        return rows.map { "\($0.0)|\($0.1)" }.joined(separator: "\n")
    }
    for _ in 0..<15 {
        guard let first = try? accessibility.frontmostTree() else { continue }
        Thread.sleep(forTimeInterval: 1.0)
        guard let second = try? accessibility.frontmostTree() else { continue }
        if signature(first) == signature(second) { return second }
    }
    return nil
}

@Test
func hitTestingFindsTheElementsOfTheMirroredPanel() throws {
    // `elementAtPoint` asks a display, and the default display is not
    // "whichever one is showing": on a two-panel device it is the cover
    // panel specifically. A pane mirroring the other panel then hit-tests a
    // display it is not showing and finds nothing, while the tree it read
    // those coordinates from came from the panel that *is* showing.
    //
    // Both reads are taken against one settled tree so the only thing that
    // differs between them is the display being asked.
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim — run via `make test-live`"
    )
    try waitForAXServer(udid: booted.udid)

    let display = try SimDisplayHandle.handle(forUDID: booted.udid)
    try display.start { _ in }
    defer { display.stop() }
    Thread.sleep(forTimeInterval: 0.5)
    let panel = display.boundScreenID

    let accessibility = try SimAccessibility.client(forUDID: booted.udid)
    let tree = try #require(
        settledTree(accessibility),
        "no two accessibility reads agreed within 15 attempts, so no hit-test could be judged"
    )
    var frames: [(String, CGRect)] = []
    framedNodes(tree, into: &frames)
    let probes = Array(frames.prefix(8))
    try #require(!probes.isEmpty, "no element with a frame in the frontmost tree")

    func hitCount() -> Int {
        probes.filter {
            (try? accessibility.elementAtPoint(CGPoint(x: $0.1.midX, y: $0.1.midY))) != nil
        }
        .count
    }
    accessibility.displayID = 0
    let viaDefault = hitCount()
    accessibility.displayID = panel
    let viaPanel = hitCount()

    // Not "finds all of them": on an unfolded foldable some frames sit
    // outside the interface size the tree reports, and those miss whichever
    // display is asked. That is a separate defect in the coordinate space,
    // not in the display being addressed, so this asserts only what
    // addressing the right panel is responsible for. On a single-display
    // device the two reads agree and the comparison is a no-op.
    #expect(viaPanel >= viaDefault, "panel \(panel) found \(viaPanel), the default display found \(viaDefault)")
    #expect(viaPanel > 0, "panel \(panel) found none of \(probes.count) elements taken from its own tree")
}
