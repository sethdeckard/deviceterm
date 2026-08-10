// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Foundation
import Testing

// PaneLocationViewModelTests: the snapshot/refresh cycle and the
// terminal-refusal rule.
//
// The behavior worth protecting: a scope refusal disables the surface
// permanently (the submenu renders one disabled row instead of retrying
// forever, the cost `.validatedGUI` imposes on a `--smoke` GUI), while
// an ordinary failure is transient and leaves the last good snapshot
// alone.

private let roleViolation = DaemonClientError.daemon(code: -32_011, message: "not the validated GUI peer")
private let unauthorized = DaemonClientError.daemon(code: -32_001, message: "stale session")
private let transientFailure = DaemonClientError.daemon(code: -32_000, message: "device busy")

@MainActor
private func makeViewModel(
    _ client: FakeDaemonClient,
    locations: any LocationsStoring = FakeLocationsStore(),
    routeFiles: any RouteFileLoading = FakeRouteFiles(),
    provider: FakeLocationProvider = FakeLocationProvider()
) -> PaneLocationViewModel {
    PaneLocationViewModel(
        paneId: "pane-1",
        client: client,
        locations: locations,
        routeFiles: routeFiles,
        makeLocationProvider: { provider }
    )
}

/// A stand-in for the filesystem half of the route path, so these tests
/// never write a `.gpx` to disk. `GPXDocumentTests` and
/// `RouteFileReaderTests` cover the real reading and parsing.
private final class FakeRouteFiles: RouteFileLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Result<SimulatedLocation, RouteFileError>] = [:]
    private var loaded: [String] = []
    /// Held open until released, so a test can observe the window in
    /// which a pane can close or a second click can arrive.
    private var gate: Gate?

    var loads: [String] { lock.withLock { loaded } }

    func stub(_ path: String, _ result: Result<SimulatedLocation, RouteFileError>) {
        lock.withLock { storage[path] = result }
    }

    func hold(_ gate: Gate) { lock.withLock { self.gate = gate } }

    func load(path: String) async throws -> SimulatedLocation {
        let gate = lock.withLock {
            loaded.append(path)
            return self.gate
        }
        await gate?.wait()
        let result = lock.withLock { storage[path] }
        switch result {
        case let .success(location):
            return location

        case let .failure(error):
            throw error

        case nil:
            throw RouteFileError.unreadable(message: "no stub for \(path)")
        }
    }
}

/// One-shot suspension a test opens and closes by hand.
private actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let resuming = waiters
        waiters = []
        for waiter in resuming { waiter.resume() }
    }
}

private let sampleRoute = SimulatedLocation.route(spec: RouteSpec(
    mode: .interval(seconds: 1),
    speed: 20,
    waypoints: [
        RouteWaypoint(latitude: 0, longitude: 0),
        RouteWaypoint(latitude: 1, longitude: 1)
    ]
))

/// A stand-in for CoreLocation. Every test uses one, so nothing in
/// `AppTests` constructs a `CLLocationManager` or reaches TCC.
@MainActor
private final class FakeLocationProvider: MacLocationProviding {
    var fix: MacLocationFix = .fix(latitude: 37.7749, longitude: -122.4194)
    private(set) var calls = 0
    /// Stands in for a permission prompt sitting on screen.
    private var gate: Gate?

    func hold(_ gate: Gate) { self.gate = gate }

    func currentFix() async -> MacLocationFix {
        calls += 1
        await gate?.wait()
        return fix
    }
}

/// An in-memory stand-in for the locations file, with the same
/// append-only dedup rule so the view model's tests never touch disk.
private final class FakeLocationsStore: LocationsStoring, @unchecked Sendable {
    /// The tests call these synchronous witnesses from `@MainActor`, so
    /// they do not hop executors; production witnesses await
    /// `LocationsFileGate`. The lock keeps the `Sendable` invariant
    /// independent of that call pattern.
    private let lock = NSLock()
    private var storage: [LocationEntry] = []

    var entries: [LocationEntry] {
        lock.withLock { storage }
    }

    func load() -> [LocationEntry] {
        lock.withLock { storage }
    }

    func record(_ entry: LocationEntry) {
        lock.withLock {
            let key = LocationsFileParser.dedupKey(for: entry)
            let isKnown = storage.contains { LocationsFileParser.dedupKey(for: $0) == key }
            if !isKnown { storage.append(entry) }
        }
    }
}

/// Let the view model's unstructured tasks run to completion.
///
/// `apply` chains two round trips (set, then the refresh that follows
/// it), and the fake awaits a real `Task.sleep` on each to mirror a
/// genuine suspension, so cooperative yields alone don't reliably drain
/// it. Short real sleeps do.
private func settle() async {
    for _ in 0..<20 {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
}

@Test
@MainActor
func refreshPublishesTheDaemonSnapshot() async {
    let client = FakeDaemonClient()
    client.locationStateResult = PaneLocationStateResult(
        location: .scenario(name: "City Run"),
        scenarios: ["City Run", "Apple"]
    )
    let viewModel = makeViewModel(client)
    viewModel.refresh()
    await settle()
    #expect(viewModel.state.location == .scenario(name: "City Run"))
    #expect(viewModel.state.scenarios == ["City Run", "Apple"])
    #expect(client.locationStateCalls == ["pane-1"])
}

@Test
@MainActor
func applySendsTheLocationAndThenRefreshes() async {
    let client = FakeDaemonClient()
    let viewModel = makeViewModel(client)
    viewModel.apply(.scenario(name: "Freeway Drive"))
    await settle()
    #expect(client.locationSetCalls == [
        .init(paneId: "pane-1", location: .scenario(name: "Freeway Drive"))
    ])
    // The refresh that follows a set is what moves the snapshot; the VM
    // never writes it optimistically.
    #expect(viewModel.state.location == .scenario(name: "Freeway Drive"))
}

/// Not optimistic, deliberately: a rejected set must leave the checkmark
/// on the daemon's last recorded claim. Here the daemon still has no
/// claim to make, so the menu goes on checking nothing rather than
/// moving onto a location the device refused.
@Test
@MainActor
func aFailedApplyDoesNotMoveTheSnapshot() async {
    let client = FakeDaemonClient()
    client.locationSetFailure = transientFailure
    let viewModel = makeViewModel(client)
    viewModel.apply(.scenario(name: "Nope"))
    await settle()
    #expect(viewModel.state.location == nil)
    // Still available: a transient failure is not a scope refusal.
    #expect(viewModel.isAvailable)
}

@Test("a scope refusal disables the surface permanently", arguments: [roleViolation, unauthorized])
@MainActor
func scopeRefusalDisablesTheSurface(error: DaemonClientError) async {
    let client = FakeDaemonClient()
    client.locationStateFailure = error
    let viewModel = makeViewModel(client)
    viewModel.refresh()
    await settle()
    #expect(!viewModel.isAvailable)

    // And it stops calling: no alert loop, no per-open retry storm.
    let callsAfterRefusal = client.locationStateCalls.count
    viewModel.refresh()
    viewModel.apply(.cleared)
    await settle()
    #expect(client.locationStateCalls.count == callsAfterRefusal)
    #expect(client.locationSetCalls.isEmpty)
}

/// A transient failure must not disable the menu. The next open should
/// try again.
@Test
@MainActor
func aTransientFailureKeepsTheSurfaceAvailable() async {
    let client = FakeDaemonClient()
    client.locationStateFailure = transientFailure
    let viewModel = makeViewModel(client)
    viewModel.refresh()
    await settle()
    #expect(viewModel.isAvailable)

    client.locationStateFailure = nil
    client.locationStateResult = PaneLocationStateResult(location: .cleared, scenarios: ["City Run"])
    viewModel.refresh()
    await settle()
    #expect(viewModel.state.scenarios == ["City Run"])
}

// MARK: - Saved locations

@Test
@MainActor
func refreshPublishesTheSavedLocations() async {
    let store = FakeLocationsStore()
    store.record(.coordinate(latitude: 37.7749, longitude: -122.4194, label: "San Francisco"))
    // Bound to a local: the view model holds its client weakly, so a
    // temporary would deallocate before the first call.
    let client = FakeDaemonClient()
    let viewModel = makeViewModel(client, locations: store)
    viewModel.refresh()
    await settle()
    #expect(viewModel.savedLocations.map(\.label) == ["San Francisco"])
}

/// Applying a typed coordinate saves it, so the point comes back as its
/// own menu row without the user having to edit a file.
@Test
@MainActor
func applyingACoordinateSavesIt() async {
    let store = FakeLocationsStore()
    let client = FakeDaemonClient()
    let viewModel = makeViewModel(client, locations: store)
    viewModel.apply(
        .coordinate(latitude: 37.7749, longitude: -122.4194),
        label: "San Francisco"
    )
    await settle()
    #expect(store.entries == [
        .coordinate(latitude: 37.7749, longitude: -122.4194, label: "San Francisco")
    ])
    // Published by the refresh that `apply` runs, so the row is there
    // without waiting for the next menu open.
    #expect(viewModel.savedLocations.map(\.label) == ["San Francisco"])
}

/// This test checks convergence only. `refresh()` is the sole writer of
/// `savedLocations`, and `record` returns no snapshot, so there is no
/// second publication channel. The synchronous fake cannot exercise
/// publication ordering.
@Test("rapid saves converge on the full list")
@MainActor
func rapidSavesDoNotRevertTheSnapshot() async {
    let store = FakeLocationsStore()
    let client = FakeDaemonClient()
    let viewModel = makeViewModel(client, locations: store)
    for index in 0..<8 {
        viewModel.apply(
            .coordinate(latitude: Double(index), longitude: 0),
            label: "P\(index)"
        )
    }
    await settle()
    #expect(store.entries.count == 8)
    #expect(
        viewModel.savedLocations.count == 8,
        "the published snapshot is older than the file"
    )
}

/// The rule that keeps the list from filling with rows nobody chose. A
/// trip and `None` are already permanent rows of the menu; saving them
/// would add a duplicate that is never evicted.
@Test("only coordinates are saved", arguments: [
    SimulatedLocation.cleared,
    .scenario(name: "City Run")
])
@MainActor
func nonCoordinatesAreNotSaved(location: SimulatedLocation) async {
    let store = FakeLocationsStore()
    let client = FakeDaemonClient()
    let viewModel = makeViewModel(client, locations: store)
    viewModel.apply(location)
    await settle()
    #expect(store.entries.isEmpty)
    // Sanity: the apply really ran. Without this the test would also
    // pass if nothing happened at all.
    #expect(client.locationSetCalls.count == 1)
}

/// Choosing a saved row re-applies it without adding a second copy, so
/// using the menu normally can't grow the file.
@Test
@MainActor
func reapplyingASavedCoordinateAddsNothing() async {
    let store = FakeLocationsStore()
    store.record(.coordinate(latitude: 37.7749, longitude: -122.4194, label: "San Francisco"))
    let client = FakeDaemonClient()
    let viewModel = makeViewModel(client, locations: store)
    viewModel.apply(.coordinate(latitude: 37.7749, longitude: -122.4194))
    await settle()
    #expect(store.entries.count == 1)
    #expect(store.entries.first?.label == "San Francisco", "the user's own label was overwritten")
    #expect(client.locationSetCalls.count == 1, "the location was still applied")
}

/// The file records the place the user chose, not whether a device
/// happened to accept it: a coordinate typed while a device is offline
/// should not be silently discarded along with the failed set.
@Test
@MainActor
func aFailedSetStillSavesTheCoordinate() async {
    let store = FakeLocationsStore()
    let client = FakeDaemonClient()
    client.locationSetFailure = transientFailure
    let viewModel = makeViewModel(client, locations: store)
    viewModel.apply(.coordinate(latitude: 37.7749, longitude: -122.4194), label: "Home")
    await settle()
    #expect(store.entries.map(\.label) == ["Home"])
}

/// A refused surface applies nothing, so it must save nothing either.
/// The file would otherwise collect entries from a menu that never
/// worked.
@Test
@MainActor
func aRefusedSurfaceSavesNothing() async {
    let store = FakeLocationsStore()
    let client = FakeDaemonClient()
    client.locationStateFailure = roleViolation
    let viewModel = makeViewModel(client, locations: store)
    viewModel.refresh()
    await settle()
    #expect(!viewModel.isAvailable)

    viewModel.apply(.coordinate(latitude: 37.7749, longitude: -122.4194), label: "Home")
    await settle()
    #expect(store.entries.isEmpty)
}

// MARK: - Use My Location

@Test("a fix is applied to the device")
@MainActor
func useMyLocationAppliesTheFix() async {
    let client = FakeDaemonClient()
    let provider = FakeLocationProvider()
    let viewModel = makeViewModel(client, provider: provider)

    let alert = await viewModel.useMyLocation(isPaneLive: { true })
    await settle()
    #expect(alert == nil, "a successful fix must not raise an alert")
    #expect(client.locationSetCalls == [
        .init(paneId: "pane-1", location: .coordinate(latitude: 37.7749, longitude: -122.4194))
    ])
}

/// The fix is rounded to the locations file's precision before it goes
/// anywhere. The menu matches the daemon's claim by exact equality, so a
/// full-precision coordinate could never check a row read from the file,
/// even for the same place. The extra digits are noise on a Wi-Fi fix in
/// any case.
@Test("a fix is canonicalized before it is applied")
@MainActor
func useMyLocationCanonicalizesTheFix() async {
    let client = FakeDaemonClient()
    let provider = FakeLocationProvider()
    provider.fix = .fix(latitude: 37.774912345678, longitude: -122.419415987654)
    let viewModel = makeViewModel(client, provider: provider)

    _ = await viewModel.useMyLocation(isPaneLive: { true })
    await settle()
    #expect(client.locationSetCalls == [
        .init(
            paneId: "pane-1",
            location: .coordinate(latitude: 37.774912, longitude: -122.419416)
        )
    ])
}

/// Deliberately not saved, unlike a typed coordinate. The file is a
/// curated list the user hand-edits and deviceterm never evicts from,
/// and "wherever I am" is not a place somebody chose: GPS jitter moves
/// the reading between clicks, so saving would append a near-duplicate
/// row on every use that only a hand edit could remove.
@Test("a fix is not written to the locations file")
@MainActor
func useMyLocationSavesNothing() async {
    let store = FakeLocationsStore()
    let client = FakeDaemonClient()
    let viewModel = makeViewModel(client, locations: store)

    _ = await viewModel.useMyLocation(isPaneLive: { true })
    await settle()
    #expect(store.entries.isEmpty)
    #expect(client.locationSetCalls.count == 1, "the fix was still applied")
}

/// Nothing reaches the device unless a position actually arrived, and
/// every failure says so. A menu item with no other feedback channel that
/// silently did nothing is indistinguishable from a broken one.
@Test("a failed fix alerts and sets nothing", arguments: [
    MacLocationFix.notDetermined,
    .denied,
    .restricted,
    .unavailable("no position")
])
@MainActor
func useMyLocationReportsEveryFailure(fix: MacLocationFix) async {
    let store = FakeLocationsStore()
    let client = FakeDaemonClient()
    let provider = FakeLocationProvider()
    provider.fix = fix
    let viewModel = makeViewModel(client, locations: store, provider: provider)

    let alert = await viewModel.useMyLocation(isPaneLive: { true })
    await settle()
    #expect(alert != nil)
    #expect(client.locationSetCalls.isEmpty)
    #expect(store.entries.isEmpty)
}

/// `kCLLocationCoordinate2DInvalid` is `(-180, -180)`: a longitude that
/// passes the range check and a latitude that does not. Caught here, it
/// becomes a sentence about the Mac's location rather than an
/// `invalidParams` about a latitude the user never typed.
@Test("an invalid coordinate is refused rather than sent")
@MainActor
func useMyLocationRefusesTheInvalidSentinel() async {
    let client = FakeDaemonClient()
    let provider = FakeLocationProvider()
    provider.fix = .fix(latitude: -180, longitude: -180)
    let viewModel = makeViewModel(client, provider: provider)

    let alert = await viewModel.useMyLocation(isPaneLive: { true })
    #expect(alert != nil)
    #expect(client.locationSetCalls.isEmpty)
}

/// A refused surface applies nothing, so it must not prompt for location
/// permission either. Asking the user for TCC access on a menu that
/// cannot work would be the worst version of this.
@Test("a refused surface never asks for a fix")
@MainActor
func aRefusedSurfaceTakesNoFix() async {
    let client = FakeDaemonClient()
    client.locationStateFailure = roleViolation
    let provider = FakeLocationProvider()
    let viewModel = makeViewModel(client, provider: provider)
    viewModel.refresh()
    await settle()
    #expect(!viewModel.isAvailable)

    let alert = await viewModel.useMyLocation(isPaneLive: { true })
    #expect(alert == nil, "a refused surface has its own disabled row; it must not alert")
    #expect(provider.calls == 0)
}

/// The provider is built on first use and then kept, so opening a pane
/// constructs no `CLLocationManager` and a second click does not build a
/// second one.
@Test
@MainActor
func theLocationProviderIsBuiltOnceAndOnlyOnDemand() async {
    let client = FakeDaemonClient()
    var builds = 0
    let provider = FakeLocationProvider()
    let viewModel = PaneLocationViewModel(
        paneId: "pane-1",
        client: client,
        locations: FakeLocationsStore(),
        makeLocationProvider: {
            builds += 1
            return provider
        }
    )
    viewModel.refresh()
    await settle()
    #expect(builds == 0, "a pane that never asks for a fix must not build a provider")

    _ = await viewModel.useMyLocation(isPaneLive: { true })
    _ = await viewModel.useMyLocation(isPaneLive: { true })
    await settle()
    #expect(builds == 1)
    #expect(provider.calls == 2)
}

/// Clicking twice must not act twice. Coalescing the fix alone would
/// still leave each click running its own set and raising its own alert,
/// so a failing fix would stack identical modal alerts on the one menu
/// item people are most likely to click again. The whole action
/// coalesces: one fix, one set, one alert.
@Test("a repeat click joins the action already running")
@MainActor
func useMyLocationCoalescesRepeatClicks() async {
    let client = FakeDaemonClient()
    client.locationSetFailure = transientFailure
    let provider = FakeLocationProvider()
    let viewModel = makeViewModel(client, provider: provider)

    async let first = viewModel.useMyLocation(isPaneLive: { true })
    async let second = viewModel.useMyLocation(isPaneLive: { true })
    let alerts = await [first, second].compactMap(\.self)
    await settle()

    #expect(provider.calls == 1)
    #expect(client.locationSetCalls.count == 1)
    #expect(alerts.count == 1, "both clicks raised their own alert")
}

/// Coalescing must not wedge the action: once one finishes, the next
/// click starts a fresh one rather than joining a completed task.
@Test("a later click runs again")
@MainActor
func useMyLocationRunsAgainAfterFinishing() async {
    let client = FakeDaemonClient()
    let provider = FakeLocationProvider()
    let viewModel = makeViewModel(client, provider: provider)

    _ = await viewModel.useMyLocation(isPaneLive: { true })
    _ = await viewModel.useMyLocation(isPaneLive: { true })
    await settle()
    #expect(provider.calls == 2)
    #expect(client.locationSetCalls.count == 2)
}

/// A pane id outlives the tab that closed it: an orphaned sim keeps its
/// record through an ownership transfer and can be adopted by another
/// session, and the GUI's connection is authorized for any live pane. An
/// unanswered permission prompt leaves the request pending for about a
/// minute, so without the fence a fix answered late would set this Mac's
/// position on a device now belonging to somebody else's tab.
@Test("a fix answered after the pane went away is dropped")
@MainActor
func useMyLocationDropsAFixForADeadPane() async {
    let store = FakeLocationsStore()
    let client = FakeDaemonClient()
    let viewModel = makeViewModel(client, locations: store)

    let alert = await viewModel.useMyLocation(isPaneLive: { false })
    await settle()
    #expect(client.locationSetCalls.isEmpty)
    #expect(alert == nil, "there is nobody left to show an alert to")
}

/// The one row whose failure is otherwise invisible. Picking a trip or a
/// saved row leaves a visibly unmoved checkmark beside the row just
/// clicked, whereas a successful fix checks a matching saved row or
/// appends a coordinate row, so its failure looks like nothing happened
/// at all. This is also why the set is awaited rather than handed to
/// `apply`, whose failures only reach the log.
@Test("a set the device refuses is reported")
@MainActor
func useMyLocationReportsARefusedSet() async {
    let client = FakeDaemonClient()
    client.locationSetFailure = transientFailure
    let viewModel = makeViewModel(client)

    let alert = await viewModel.useMyLocation(isPaneLive: { true })
    await settle()
    #expect(alert != nil)
    #expect(client.locationSetCalls.count == 1, "the set was still attempted")
    #expect(viewModel.isAvailable, "a transient failure is not a scope refusal")
    // The daemon's own words, not Foundation's "operation couldn't be
    // completed" placeholder. `DaemonClientError` is
    // `CustomStringConvertible`, not `LocalizedError`, so reaching for
    // `localizedDescription` would discard the code and the message and
    // leave the user an alert that says nothing.
    #expect(alert?.body.contains("device busy") == true)
}

/// A scope refusal has already disabled the whole submenu, which is its
/// own explanation. A second complaint on top would be noise.
@Test("a scope refusal on the set does not also alert")
@MainActor
func useMyLocationStaysQuietOnAScopeRefusal() async {
    let client = FakeDaemonClient()
    client.locationSetFailure = roleViolation
    let viewModel = makeViewModel(client)

    let alert = await viewModel.useMyLocation(isPaneLive: { true })
    await settle()
    #expect(alert == nil)
    #expect(!viewModel.isAvailable)
}

/// A client whose RPCs park until released, so a test can hold a request
/// in flight and observe what it retains.
@MainActor
private final class ParkingLocationClient: PaneLocationControlling {
    private(set) var isParked = false
    private var waiter: CheckedContinuation<Void, Never>?

    func paneLocationSet(paneId: String, location: SimulatedLocation) async {
        await park()
    }

    func paneLocationState(paneId: String) async -> PaneLocationStateResult {
        await park()
        return PaneLocationStateResult(location: nil, scenarios: [])
    }

    func release() {
        waiter?.resume()
        waiter = nil
    }

    private func park() async {
        isParked = true
        await withCheckedContinuation { waiter = $0 }
    }
}

/// The view model must not be kept alive by its own in-flight request.
///
/// `self` owns `refreshTask`, so promoting `[weak self]` before the
/// `await` would close a cycle for the duration of the RPC, and a
/// `devicectl` enumeration can hang for a long time, pinning a pane the
/// user already closed. Same shape for `apply`, which holds no cycle but
/// would still pin the view model.
@Test("an in-flight request does not retain the view model", arguments: [true, false])
@MainActor
func inFlightRequestDoesNotRetainTheViewModel(useApply: Bool) async {
    let client = ParkingLocationClient()
    var viewModel: PaneLocationViewModel? = PaneLocationViewModel(
        paneId: "pane-1",
        client: client,
        locations: FakeLocationsStore()
    )
    weak let released = viewModel

    if useApply {
        viewModel?.apply(.cleared)
    } else {
        viewModel?.refresh()
    }
    while !client.isParked { await Task.yield() }

    // Drop the last strong reference while the request is still parked.
    viewModel = nil
    #expect(released == nil, "the in-flight request is keeping the view model alive")

    client.release()
}

/// A client whose *first* read parks and then fails, so a test can let a
/// superseded request lose the race and still try to report.
@MainActor
private final class SupersedableLocationClient: PaneLocationControlling {
    private(set) var isParked = false
    /// Thrown by the first `paneLocationState` once released.
    var firstReadFailure: (any Error)?
    private var reads = 0
    private var waiter: CheckedContinuation<Void, Never>?

    // swiftlint:disable:next async_without_await
    func paneLocationSet(paneId: String, location: SimulatedLocation) async {}

    func paneLocationState(paneId: String) async throws -> PaneLocationStateResult {
        reads += 1
        if reads == 1 {
            isParked = true
            await withCheckedContinuation { waiter = $0 }
            if let firstReadFailure { throw firstReadFailure }
        }
        return PaneLocationStateResult(location: nil, scenarios: [])
    }

    func release() {
        waiter?.resume()
        waiter = nil
    }
}

/// A superseded refresh must not be able to disable the menu.
///
/// Guarding only the success path on `Task.isCancelled` isn't enough: a
/// cancelled request typically fails with whatever the transport
/// reports, not a `CancellationError`, so a stale error carrying a
/// terminal code would win the race and set `isAvailable = false`
/// permanently, on the strength of a request already replaced.
@Test
@MainActor
func aSupersededRefreshCannotDisableTheSurface() async {
    let client = SupersedableLocationClient()
    client.firstReadFailure = roleViolation
    let viewModel = PaneLocationViewModel(
        paneId: "pane-1",
        client: client,
        locations: FakeLocationsStore()
    )

    viewModel.refresh()
    while !client.isParked { await Task.yield() }
    // A newer refresh supersedes and cancels the parked one.
    viewModel.refresh()
    client.release()
    await settle()

    #expect(viewModel.isAvailable, "a superseded request's terminal error disabled the menu")
}

/// A failed read leaves the previous snapshot in place rather than
/// blanking the menu.
@Test
@MainActor
func aFailedRefreshKeepsTheLastGoodSnapshot() async {
    let client = FakeDaemonClient()
    client.locationStateResult = PaneLocationStateResult(
        location: .scenario(name: "Apple"),
        scenarios: ["Apple"]
    )
    let viewModel = makeViewModel(client)
    viewModel.refresh()
    await settle()

    client.locationStateFailure = transientFailure
    viewModel.refresh()
    await settle()
    #expect(viewModel.state.location == .scenario(name: "Apple"))
    #expect(viewModel.state.scenarios == ["Apple"])
}

// MARK: - Routes

@Test
@MainActor
func applyRouteSendsWhatTheFileParsedTo() async {
    let client = FakeDaemonClient()
    let routes = FakeRouteFiles()
    routes.stub("/routes/run.gpx", .success(sampleRoute))
    let viewModel = makeViewModel(client, routeFiles: routes)

    let alert = await viewModel.applyRoute(path: "/routes/run.gpx", isPaneLive: { true })
    await settle()

    #expect(alert == nil)
    #expect(routes.loads == ["/routes/run.gpx"])
    #expect(client.locationSetCalls.map(\.location) == [sampleRoute])
    #expect(viewModel.activeRoutePath == "/routes/run.gpx")
}

/// The checkmark can only follow a route the daemon actually took.
@Test
@MainActor
func aRefusedRouteIsNotRemembered() async {
    let client = FakeDaemonClient()
    client.locationSetFailure = transientFailure
    let routes = FakeRouteFiles()
    routes.stub("/routes/run.gpx", .success(sampleRoute))
    let viewModel = makeViewModel(client, routeFiles: routes)

    let alert = await viewModel.applyRoute(path: "/routes/run.gpx", isPaneLive: { true })
    await settle()

    #expect(alert != nil)
    #expect(viewModel.activeRoutePath == nil)
}

/// The stronger half of the rule: the route is recorded **after** the
/// daemon takes it, not before and rolled back.
///
/// The refresh that follows a failure normally repairs an early write,
/// which is why the check above holds whichever side of the call the
/// route is recorded on, and why this one fails the refresh too.
/// Otherwise there is a window in which the menu shows a checkmark for
/// a route the device refused, and a refresh that is itself failing
/// never closes it.
@Test
@MainActor
func aRefusedRouteIsNotRememberedEvenIfTheRefreshAlsoFails() async {
    let client = FakeDaemonClient()
    client.locationSetFailure = transientFailure
    client.locationStateFailure = transientFailure
    let routes = FakeRouteFiles()
    routes.stub("/routes/run.gpx", .success(sampleRoute))
    let viewModel = makeViewModel(client, routeFiles: routes)

    _ = await viewModel.applyRoute(path: "/routes/run.gpx", isPaneLive: { true })
    await settle()

    #expect(viewModel.activeRoutePath == nil)
}

/// Every load failure alerts, because the checkmark not moving is
/// otherwise indistinguishable from a row that does nothing.
@Test("a file that won't load alerts rather than failing silently", arguments: [
    RouteFileError.unreadable(message: "No such file"),
    .malformed(.noPoints),
    .unusable(.tooFewWaypoints(count: 1))
])
@MainActor
func routeLoadFailuresAlert(error: RouteFileError) async {
    let client = FakeDaemonClient()
    let routes = FakeRouteFiles()
    routes.stub("/routes/run.gpx", .failure(error))
    let viewModel = makeViewModel(client, routeFiles: routes)

    let alert = await viewModel.applyRoute(path: "/routes/run.gpx", isPaneLive: { true })
    #expect(alert != nil)
    #expect(alert?.body.contains("/routes/run.gpx") == true, "the alert didn't name the file")
    #expect(client.locationSetCalls.isEmpty, "a failed load still sent a set")
}

/// A route is never written back to the locations file. It is already a
/// line in it, and a one-point `.gpx` applies as a coordinate, which
/// `apply` *would* save: routing it through here instead is what keeps
/// a second row from appearing for a file that already has one.
@Test
@MainActor
func applyingARouteSavesNothing() async {
    let client = FakeDaemonClient()
    let store = FakeLocationsStore()
    let routes = FakeRouteFiles()
    routes.stub("/routes/sf.gpx", .success(.coordinate(latitude: 37.7749, longitude: -122.4194)))
    let viewModel = makeViewModel(client, locations: store, routeFiles: routes)

    _ = await viewModel.applyRoute(path: "/routes/sf.gpx", isPaneLive: { true })
    await settle()

    #expect(store.entries.isEmpty)
}

/// A pane id outlives the tab that closed it: an orphaned sim keeps its
/// record through `transferOwnership` and can be adopted by another
/// session, and the GUI is authorized for any live pane. So a route
/// answered after the pane went away would land on somebody else's
/// device.
@Test
@MainActor
func aRouteForAClosedPaneIsNotSent() async {
    let client = FakeDaemonClient()
    let routes = FakeRouteFiles()
    routes.stub("/routes/run.gpx", .success(sampleRoute))
    let viewModel = makeViewModel(client, routeFiles: routes)

    let alert = await viewModel.applyRoute(path: "/routes/run.gpx", isPaneLive: { false })
    await settle()

    #expect(alert == nil, "a closed pane has nobody left to tell")
    #expect(client.locationSetCalls.isEmpty)
}

/// The coalescing rule. Without it a second click opens the file again,
/// sends a second set, and stacks a second identical modal alert behind
/// the first, which is exactly what a row that looks like it did nothing
/// invites.
@Test
@MainActor
func repeatClicksOnOneRouteJoinTheFirst() async {
    let client = FakeDaemonClient()
    let routes = FakeRouteFiles()
    routes.stub("/routes/run.gpx", .success(sampleRoute))
    let gate = Gate()
    routes.hold(gate)
    let viewModel = makeViewModel(client, routeFiles: routes)

    async let first = viewModel.applyRoute(path: "/routes/run.gpx", isPaneLive: { true })
    await settle()
    async let second = viewModel.applyRoute(path: "/routes/run.gpx", isPaneLive: { true })
    await settle()
    await gate.open()
    _ = await (first, second)
    await settle()

    #expect(routes.loads == ["/routes/run.gpx"], "the file was opened twice")
    #expect(client.locationSetCalls.count == 1)
}

/// Two *different* routes are two different intentions, so they both
/// run; the daemon serializes them per pane.
@Test
@MainActor
func twoDifferentRoutesBothRun() async {
    let client = FakeDaemonClient()
    let routes = FakeRouteFiles()
    routes.stub("/routes/a.gpx", .success(sampleRoute))
    routes.stub("/routes/b.gpx", .success(sampleRoute))
    let viewModel = makeViewModel(client, routeFiles: routes)

    _ = await viewModel.applyRoute(path: "/routes/a.gpx", isPaneLive: { true })
    _ = await viewModel.applyRoute(path: "/routes/b.gpx", isPaneLive: { true })
    await settle()

    #expect(routes.loads == ["/routes/a.gpx", "/routes/b.gpx"])
    #expect(client.locationSetCalls.count == 2)
}

/// The remembered route is released the moment the daemon's claim stops
/// being the one that route produced, so the checkmark can't stay on a
/// row some other choice has replaced.
@Test
@MainActor
func choosingSomethingElseReleasesTheRoute() async {
    let client = FakeDaemonClient()
    let routes = FakeRouteFiles()
    routes.stub("/routes/run.gpx", .success(sampleRoute))
    let viewModel = makeViewModel(client, routeFiles: routes)

    _ = await viewModel.applyRoute(path: "/routes/run.gpx", isPaneLive: { true })
    await settle()
    #expect(viewModel.activeRoutePath == "/routes/run.gpx")

    viewModel.apply(.scenario(name: "City Run"))
    await settle()
    #expect(viewModel.activeRoutePath == nil)
}

/// Including a claim the daemon dropped on its own: an ownership
/// transfer or a shutdown resets it to `nil`, and no row may go on
/// asserting one.
@Test
@MainActor
func aDroppedClaimReleasesTheRoute() async {
    let client = FakeDaemonClient()
    let routes = FakeRouteFiles()
    routes.stub("/routes/run.gpx", .success(sampleRoute))
    let viewModel = makeViewModel(client, routeFiles: routes)

    _ = await viewModel.applyRoute(path: "/routes/run.gpx", isPaneLive: { true })
    await settle()
    #expect(viewModel.activeRoutePath == "/routes/run.gpx")

    client.locationStateResult = PaneLocationStateResult(location: nil, scenarios: [])
    viewModel.refresh()
    await settle()
    #expect(viewModel.activeRoutePath == nil)
}

/// A scope refusal has already disabled the whole submenu, which is a
/// louder and more durable answer than an alert.
@Test
@MainActor
func aRefusedSurfaceStaysQuietOnRoutes() async {
    let client = FakeDaemonClient()
    client.locationSetFailure = roleViolation
    let routes = FakeRouteFiles()
    routes.stub("/routes/run.gpx", .success(sampleRoute))
    let viewModel = makeViewModel(client, routeFiles: routes)

    let alert = await viewModel.applyRoute(path: "/routes/run.gpx", isPaneLive: { true })
    #expect(alert == nil)
    #expect(!viewModel.isAvailable)
}

// MARK: - Superseded selections

// Every row suspends before it reaches the daemon, so a slow one can be
// overtaken by a later choice and then land *after* it, leaving the
// device at the location the user gave up on. Per-pane serialization in
// the daemon doesn't help: it preserves arrival order, which is the
// order that is wrong here.

/// A route is still reading its file when a trip is picked. The trip
/// must be the last location sent.
@Test
@MainActor
func aRouteOvertakenByAnotherChoiceIsAbandoned() async {
    let client = FakeDaemonClient()
    let routes = FakeRouteFiles()
    routes.stub("/routes/run.gpx", .success(sampleRoute))
    let gate = Gate()
    routes.hold(gate)
    let viewModel = makeViewModel(client, routeFiles: routes)

    async let pending = viewModel.applyRoute(path: "/routes/run.gpx", isPaneLive: { true })
    await settle()
    // The user gives up on the route and picks a trip.
    viewModel.apply(.scenario(name: "City Run"))
    await settle()
    // Only now does the file finish loading.
    await gate.open()
    let alert = await pending
    await settle()

    #expect(alert == nil, "a superseded choice must not alert about itself")
    #expect(
        client.locationSetCalls.map(\.location) == [.scenario(name: "City Run")],
        "the abandoned route reached the device"
    )
    #expect(viewModel.activeRoutePath == nil)
}

/// The longest suspension of the three: an unanswered permission prompt
/// holds Use My Location for about a minute, which is ample time to give
/// up and pick something else.
@Test
@MainActor
func aFixOvertakenByAnotherChoiceIsAbandoned() async {
    let client = FakeDaemonClient()
    let provider = FakeLocationProvider()
    let gate = Gate()
    provider.hold(gate)
    let viewModel = makeViewModel(client, provider: provider)

    async let pending = viewModel.useMyLocation(isPaneLive: { true })
    await settle()
    viewModel.apply(.cleared)
    await settle()
    await gate.open()
    let alert = await pending
    await settle()

    #expect(alert == nil)
    #expect(client.locationSetCalls.map(\.location) == [.cleared])
}

/// A failure the user *should* see still alerts: it is about the file,
/// not about which location won, and staying silent would leave a
/// broken row looking like it merely lost a race.
@Test
@MainActor
func anOvertakenRouteStillReportsAnUnreadableFile() async {
    let client = FakeDaemonClient()
    let routes = FakeRouteFiles()
    routes.stub("/routes/run.gpx", .failure(.unreadable(message: "No such file")))
    let gate = Gate()
    routes.hold(gate)
    let viewModel = makeViewModel(client, routeFiles: routes)

    async let pending = viewModel.applyRoute(path: "/routes/run.gpx", isPaneLive: { true })
    await settle()
    viewModel.apply(.scenario(name: "City Run"))
    await settle()
    await gate.open()
    let alert = await pending
    await settle()

    #expect(alert != nil, "a missing file is worth saying even if the choice moved on")
}

/// The saved row is the user's, and keeping it is independent of which
/// location ended up applied.
@Test
@MainActor
func anOvertakenCoordinateIsStillSaved() async {
    let client = FakeDaemonClient()
    let store = FakeLocationsStore()
    let viewModel = makeViewModel(client, locations: store)

    viewModel.apply(.coordinate(latitude: 37.7749, longitude: -122.4194), label: "SF")
    viewModel.apply(.scenario(name: "City Run"))
    await settle()

    #expect(store.entries.count == 1)
    #expect(client.locationSetCalls.map(\.location) == [.scenario(name: "City Run")])
}

/// Coalesced clicks are the same choice, not a newer one, so joining
/// must not make the first click supersede itself and send nothing.
@Test
@MainActor
func repeatClicksDoNotSupersedeTheChoiceTheyJoin() async {
    let client = FakeDaemonClient()
    let routes = FakeRouteFiles()
    routes.stub("/routes/run.gpx", .success(sampleRoute))
    let gate = Gate()
    routes.hold(gate)
    let viewModel = makeViewModel(client, routeFiles: routes)

    async let first = viewModel.applyRoute(path: "/routes/run.gpx", isPaneLive: { true })
    await settle()
    async let second = viewModel.applyRoute(path: "/routes/run.gpx", isPaneLive: { true })
    await settle()
    await gate.open()
    _ = await (first, second)
    await settle()

    #expect(client.locationSetCalls.map(\.location) == [sampleRoute])
}

/// A, B, A. The last click means A again, but the A still in flight was
/// superseded by B and is on its way to abandoning itself. Joining it
/// would leave B applied and the user's newest choice dropped, so the
/// re-click starts fresh work instead.
@Test
@MainActor
func reselectingAnOvertakenRouteRunsAgain() async {
    let client = FakeDaemonClient()
    let routes = FakeRouteFiles()
    routes.stub("/routes/run.gpx", .success(sampleRoute))
    let first = Gate()
    routes.hold(first)
    let viewModel = makeViewModel(client, routeFiles: routes)

    async let overtaken = viewModel.applyRoute(path: "/routes/run.gpx", isPaneLive: { true })
    await settle()
    viewModel.apply(.scenario(name: "City Run"))
    await settle()
    // The user changes their mind back.
    let reopened = Gate()
    routes.hold(reopened)
    async let reselected = viewModel.applyRoute(path: "/routes/run.gpx", isPaneLive: { true })
    await settle()
    await first.open()
    await reopened.open()
    _ = await (overtaken, reselected)
    await settle()

    #expect(client.locationSetCalls.map(\.location) == [.scenario(name: "City Run"), sampleRoute])
    #expect(viewModel.activeRoutePath == "/routes/run.gpx")
}

/// The same shape for Use My Location, whose in-flight window is the
/// longest of the three.
@Test
@MainActor
func reselectingAnOvertakenFixRunsAgain() async {
    let client = FakeDaemonClient()
    let provider = FakeLocationProvider()
    let first = Gate()
    provider.hold(first)
    let viewModel = makeViewModel(client, provider: provider)

    async let overtaken = viewModel.useMyLocation(isPaneLive: { true })
    await settle()
    viewModel.apply(.scenario(name: "City Run"))
    await settle()
    let reopened = Gate()
    provider.hold(reopened)
    async let reselected = viewModel.useMyLocation(isPaneLive: { true })
    await settle()
    await first.open()
    await reopened.open()
    _ = await (overtaken, reselected)
    await settle()

    #expect(client.locationSetCalls.count == 2)
    #expect(client.locationSetCalls.last?.location == .coordinate(latitude: 37.7749, longitude: -122.4194))
}

/// The set itself suspends, so a *newer* choice can arrive while it is
/// in flight. A failure landing after that is about a route the user has
/// already replaced, and a modal alert for it is noise on top of a
/// checkmark that is already elsewhere.
@Test
@MainActor
func aRouteFailingAfterBeingOvertakenDoesNotAlert() async {
    let client = FakeDaemonClient()
    client.locationSetFailure = transientFailure
    client.holdLocationSet = true
    let routes = FakeRouteFiles()
    routes.stub("/routes/run.gpx", .success(sampleRoute))
    let viewModel = makeViewModel(client, routeFiles: routes)

    async let pending = viewModel.applyRoute(path: "/routes/run.gpx", isPaneLive: { true })
    await settle()
    // The route has been dispatched and is awaiting the daemon; the
    // user picks something else in the meantime.
    viewModel.apply(.scenario(name: "City Run"))
    await settle()
    client.releaseLocationSet()
    let alert = await pending
    await settle()

    #expect(alert == nil, "a superseded failure raised a modal alert")
}

/// And on the success side: publishing the checkmark for a route the
/// user has moved past leaves it visibly wrong until some later refresh
/// happens to correct it.
///
/// The refresh is failed here on purpose. Letting it succeed makes the
/// test pass whether or not the fence exists, because reconciliation
/// repairs the checkmark a moment later; the window only stays open when
/// the refresh is *also* failing, which is exactly when a stale
/// checkmark is worst.
@Test
@MainActor
func aRouteSucceedingAfterBeingOvertakenIsNotPublished() async {
    let client = FakeDaemonClient()
    client.holdLocationSet = true
    client.locationStateFailure = transientFailure
    let routes = FakeRouteFiles()
    routes.stub("/routes/run.gpx", .success(sampleRoute))
    let viewModel = makeViewModel(client, routeFiles: routes)

    async let pending = viewModel.applyRoute(path: "/routes/run.gpx", isPaneLive: { true })
    await settle()
    viewModel.apply(.scenario(name: "City Run"))
    await settle()
    client.releaseLocationSet()
    _ = await pending
    await settle()

    #expect(viewModel.activeRoutePath == nil)
}

/// The Use My Location half of the same rule.
@Test
@MainActor
func aFixFailingAfterBeingOvertakenDoesNotAlert() async {
    let client = FakeDaemonClient()
    client.locationSetFailure = transientFailure
    client.holdLocationSet = true
    let viewModel = makeViewModel(client)

    async let pending = viewModel.useMyLocation(isPaneLive: { true })
    await settle()
    viewModel.apply(.scenario(name: "City Run"))
    await settle()
    client.releaseLocationSet()
    let alert = await pending
    await settle()

    #expect(alert == nil, "a superseded fix failure raised a modal alert")
}

/// A finished action must not clear an entry that is no longer its own.
/// After A, B, A the map holds the *second* A; if the first one's
/// cleanup wiped it on the way out, a further click would start a third
/// run instead of joining the second, which is the duplicate work
/// coalescing exists to prevent.
@Test
@MainActor
func aStaleActionDoesNotClearItsSuccessor() async {
    let client = FakeDaemonClient()
    let routes = FakeRouteFiles()
    routes.stub("/routes/run.gpx", .success(sampleRoute))
    let first = Gate()
    routes.hold(first)
    let viewModel = makeViewModel(client, routeFiles: routes)

    async let overtaken = viewModel.applyRoute(path: "/routes/run.gpx", isPaneLive: { true })
    await settle()
    viewModel.apply(.scenario(name: "City Run"))
    await settle()
    let second = Gate()
    routes.hold(second)
    async let reselected = viewModel.applyRoute(path: "/routes/run.gpx", isPaneLive: { true })
    await settle()
    // The superseded action finishes and tidies up while the newer one
    // is still loading.
    await first.open()
    await settle()
    // A further click on the same row must join the one in flight.
    async let joined = viewModel.applyRoute(path: "/routes/run.gpx", isPaneLive: { true })
    await settle()
    await second.open()
    _ = await (overtaken, reselected, joined)
    await settle()

    #expect(routes.loads.count == 2, "the third click opened the file again")
}

/// The Use My Location twin: a superseded fix must not clear the entry
/// belonging to the one that replaced it, or a further click would raise
/// a second permission request instead of joining the one on screen.
@Test
@MainActor
func aStaleFixDoesNotClearItsSuccessor() async {
    let client = FakeDaemonClient()
    let provider = FakeLocationProvider()
    let first = Gate()
    provider.hold(first)
    let viewModel = makeViewModel(client, provider: provider)

    async let overtaken = viewModel.useMyLocation(isPaneLive: { true })
    await settle()
    viewModel.apply(.scenario(name: "City Run"))
    await settle()
    let second = Gate()
    provider.hold(second)
    async let reselected = viewModel.useMyLocation(isPaneLive: { true })
    await settle()
    await first.open()
    await settle()
    async let joined = viewModel.useMyLocation(isPaneLive: { true })
    await settle()
    await second.open()
    _ = await (overtaken, reselected, joined)
    await settle()

    #expect(provider.calls == 2, "the third click asked for a third fix")
}
