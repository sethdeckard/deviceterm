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
    // the daemon uses (`AXSweep.gridPoints` + `hitTestPoint` +
    // `elementAtPoint`) and confirms a freshly-booted sim yields
    // at least one element regardless of family. The bridge's
    // `accessibilityChildren` is empty on watchOS, but
    // `elementAtPoint` resolves real elements; sweep aggregates
    // those. The scaling step is what this guards: drop it and
    // every grid point lands sub-pixel near `(0,0)`, so the sweep
    // returns empty on every screen.
    //
    // The track boots its own sim for a clean slate, so the device
    // is portrait, where the tree's two spaces coincide.
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
        let pixel = AXSweep.hitTestPoint(
            displayed: displayed,
            geometry: AXSweep.TreeGeometry(hitTest: interface, viewer: interface)
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
    let center = AXSweep.hitTestPoint(
        displayed: CGPoint(x: 0.5, y: 0.5),
        geometry: AXSweep.TreeGeometry(hitTest: interface, viewer: interface)
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
    let children = node["children"] as? [[String: Any]] ?? []
    if let frame = node["frame"] as? [String: Any],
        let originX = frame["x"] as? Double, let originY = frame["y"] as? Double,
        let width = frame["w"] as? Double, let height = frame["h"] as? Double,
        width > 0, height > 0 {
        out.append((
            "\(role)|\(label)",
            CGRect(x: originX, y: originY, width: width, height: height)
        ))
    }
    for child in children { framedNodes(child, into: &out) }
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

/// Whether the booted device turns its interface when rotated. iPhone keeps
/// Settings portrait however the device is held, so only a pad exercises the
/// landscape geometry.
private func bootedDeviceRotatesItsInterface() -> Bool {
    let identifier = (try? SimDeviceHandle.singleBootedDevice())?
        .deviceTypeIdentifier ?? ""
    return DeviceFamilyClassifier.classify(identifier) == .pad
}

@Test(.enabled(if: bootedDeviceRotatesItsInterface()))
func aDisplayedPointReachesTheElementUnderItInLandscape() throws {
    // In landscape the displayed centre must map to the interface centre and
    // resolve the same element. That is true of any rotation and needs no
    // device knowledge to assert.
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim — run via `make test-live`"
    )
    try waitForAXServer(udid: booted.udid)
    let purple = try SimPurpleHID.client(forUDID: booted.udid)
    try purple.rotate(to: Orientation.landscapeLeft.bridgeValue)
    // Put the device back before returning, and wait for it: this is the
    // shared simulator, and a sibling test starting mid-rotation reads a
    // screen that is neither orientation.
    defer {
        try? purple.rotate(to: Orientation.portrait.bridgeValue)
        Thread.sleep(forTimeInterval: 3.0)
    }
    Thread.sleep(forTimeInterval: 3.0)

    let accessibility = try SimAccessibility.client(forUDID: booted.udid)
    let tree = try #require(
        settledTree(accessibility),
        "the tree never stopped changing, so no hit-test could be judged"
    )
    let geometry = try #require(AXSweep.geometry(fromTree: tree))
    let viaCentre = AXSweep.hitTestPoint(
        displayed: CGPoint(x: 0.5, y: 0.5),
        geometry: geometry
    )
    let middle = CGPoint(x: geometry.hitTest.width / 2, y: geometry.hitTest.height / 2)
    #expect(
        abs(viaCentre.x - middle.x) < 1 && abs(viaCentre.y - middle.y) < 1,
        "displayed centre mapped to \(viaCentre), want \(middle)"
    )
    let atCentre = try #require(
        try? accessibility.elementAtPoint(viaCentre),
        "nothing under the displayed centre in landscape"
    )
    let atMiddle = try? accessibility.elementAtPoint(middle)
    #expect(
        AXSweep.dedupKey(element: atCentre) == AXSweep.dedupKey(element: atMiddle ?? [:]),
        "the displayed centre and the interface centre found different elements"
    )
}

/// Whether the booted device vends a second panel.
private func bootedDeviceIsTwoPanel() -> Bool {
    guard let booted = try? SimDeviceHandle.singleBootedDevice() else { return false }
    return SimDisplayHandle.deviceHasMultiplePanels(udid: booted.udid)
}

@Test(.enabled(if: bootedDeviceIsTwoPanel()))
func everyElementOfATurnedPanelIsReachableByPoint() async throws {
    // A foldable's inner panel reports its children turned a quarter from the
    // rectangle it hit-tests in. Each displayed probe must return an element
    // whose frame contains that probe, including probes past the root's
    // reported width.
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim — run via `make test-live`"
    )
    try waitForAXServer(udid: booted.udid)

    // Unfold, rather than read whatever posture the device is in. The track
    // boots from a clean slate at 0 degrees, where the two spaces coincide,
    // so a test that took the posture as it found it would only ever exercise
    // the turned case by accident.
    let backend = try SimBackendAcquirer.acquireFromBridge(udid: booted.udid).backend
    try await withDeviceUnfolded(backend) {
        // Put a turned app on screen. `frontmostTree` takes no display, and the
        // home screen is not laid out turned even on the inner panel, so whatever
        // happened to be frontmost would decide whether this case is present.
        let launch = Process()
        launch.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        launch.arguments = ["simctl", "launch", booted.udid, "com.apple.Preferences"]
        launch.standardOutput = FileHandle.nullDevice
        launch.standardError = FileHandle.nullDevice
        try launch.run()
        launch.waitUntilExit()
        try await Task.sleep(nanoseconds: 4_000_000_000)

        let display = try SimDisplayHandle.handle(forUDID: booted.udid)
        try display.start { _ in }
        defer { display.stop() }
        try await Task.sleep(nanoseconds: 500_000_000)

        let accessibility = try SimAccessibility.client(forUDID: booted.udid)
        accessibility.displayID = display.boundScreenID
        let tree = try #require(
            settledTree(accessibility),
            "the tree never stopped changing, so no hit-test could be judged"
        )
        let geometry = try #require(AXSweep.geometry(fromTree: tree))
        // On a folded device the two spaces coincide and every assertion below
        // would hold without the transform ever running, so a run that did not
        // reach the turned panel is a failure rather than a pass.
        try #require(geometry.isTurned, "the inner panel never came up turned")
        // Ask in displayed space and check the answer covers where the question
        // pointed, rather than probing element centres and demanding identity
        // back. Identity cannot be judged here: the serialized tree is not always
        // complete, so a container arrives looking like a leaf and correctly
        // answers its own centre with a child. Containment is the property the
        // transform actually owes, and it holds for a container and a leaf alike.
        let displayedProbes: [(Double, Double)] = [
            (0.15, 0.30), (0.35, 0.50), (0.55, 0.40), (0.75, 0.60), (0.90, 0.50)
        ]
        // Two of those sit past the root's own width once scaled into the viewer,
        // which is the strip that was unreachable at any point before.
        try #require(displayedProbes.contains { $0.0 * geometry.viewer.width > geometry.hitTest.width })

        var wrong: [String] = []
        for (displayedX, displayedY) in displayedProbes {
            let displayed = CGPoint(x: displayedX, y: displayedY)
            let point = AXSweep.hitTestPoint(displayed: displayed, geometry: geometry)
            let expected = CGPoint(
                x: displayedX * geometry.viewer.width,
                y: displayedY * geometry.viewer.height
            )
            // Both numbers travel with a failure: this is read against a live
            // screen nobody can re-inspect after the run, and they are what
            // separates a bad transform from an empty patch of screen.
            let probed = "\(displayed)->\(point) expecting to cover \(expected)"
            guard let found = try? accessibility.elementAtPoint(point) else {
                wrong.append("\(probed): nothing")
                continue
            }
            let box = found["frame"] as? [String: Any] ?? [:]
            let rect = CGRect(
                x: box["x"] as? Double ?? .nan,
                y: box["y"] as? Double ?? .nan,
                width: box["w"] as? Double ?? .nan,
                height: box["h"] as? Double ?? .nan
            )
            let role = found["role"] as? String ?? "?"
            let label = found["label"] as? String ?? found["identifier"] as? String ?? ""
            guard !rect.insetBy(dx: -1, dy: -1).contains(expected) else { continue }
            wrong.append("\(probed): got \(role)|\(label)@\(rect)")
        }
        #expect(
            wrong.isEmpty,
            "viewer=\(geometry.viewer) hit=\(geometry.hitTest); \(wrong.joined(separator: "; "))"
        )
    }
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
