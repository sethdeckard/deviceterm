// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import os

/// Presentation state for Device ▸ Location on
/// one pane.
///
/// `@MainActor @Observable`, bound through the `App.observe { }` helper
/// like the other pane view models. It holds a *snapshot* the menu reads
/// synchronously; refreshing happens off to the side in a `Task` and
/// never blocks menu construction. A refresh that lands while a menu is
/// open doesn't retro-update it. A later open uses the refresh once it
/// completes, the same bargain `SimulatorPaneViewModel` makes for
/// orientation.
@MainActor
@Observable
final class PaneLocationViewModel {
    /// An action still running, and the choice it belongs to.
    ///
    /// Pairing the two is what keeps coalescing from swallowing a
    /// *re-selection*. In an A, B, A sequence the last click means A
    /// again, but the A still in flight was superseded by B and is on
    /// its way to abandoning itself: joining it would leave B applied
    /// and the user's latest choice dropped. A repeat click joins only
    /// while the running action is still the current one.
    private struct InFlightAction {
        let intent: UInt64
        let task: Task<LocationAlert?, Never>
    }

    /// Mirror of the daemon's `RPCMethodError.scopeViolationCode`.
    /// Duplicated rather than imported because the App module doesn't
    /// link the daemon; the same mirroring appears in
    /// `DisplayTitlePublisher` and `AppCommandSubscriber`.
    private static let scopeViolationCode = -32_011
    /// Mirror of the daemon's `RPCMethodError.unauthorizedCode`.
    private static let unauthorizedCode = -32_001

    /// The last state read from the daemon.
    ///
    /// Starts with **no claim** (`location: nil`) rather than
    /// `.cleared`, so a menu opened before the first refresh lands checks
    /// nothing instead of asserting the device isn't simulating anything.
    /// The two are different statements; see `PaneLocationStateResult`.
    private(set) var state = PaneLocationStateResult(location: nil, scenarios: [])

    /// False once the daemon has refused this surface outright.
    ///
    /// The location methods are `.validatedGUI`, so a GUI running over
    /// the UDS fallback (`--smoke`) can never reach them, exactly as it
    /// can't reach `app.commands`. That refusal is **terminal**, not
    /// transient: retrying produces the identical error forever. The
    /// submenu renders a single disabled row in that case rather than
    /// alerting on a loop.
    private(set) var isAvailable = true

    /// The user's saved locations, in file order, as of the last refresh.
    ///
    /// Re-read from disk on every refresh rather than cached across
    /// them, so a hand-edit to the file needs nothing invalidated to be
    /// picked up. It becomes *visible* one open later than that
    /// suggests: `menuNeedsUpdate` builds its rows from this snapshot
    /// and only then starts the read, so an edit made just before an
    /// open appears on the following one.
    private(set) var savedLocations: [LocationEntry] = []

    /// The `.gpx` row whose location the daemon currently claims, or nil.
    ///
    /// A route's checkmark can't be derived from the claim the way the
    /// other rows' can: the claim carries waypoints and the row carries
    /// a path, and matching them up would mean opening the file while a
    /// menu is being drawn. So this remembers which row produced the
    /// claim, and `refresh()` drops it the moment the claim stops being
    /// the one that row applied.
    var activeRoutePath: String? { activeRoute?.path }

    /// The route applied and the location it produced, kept together so
    /// the claim can be *checked*, not just remembered. Holding the path
    /// alone would leave the checkmark on a route after some other row
    /// replaced it.
    private var activeRoute: (path: String, location: SimulatedLocation)?

    /// Bumped by every menu action that expresses a choice, so a slow
    /// one can tell it has been superseded.
    ///
    /// Every row suspends before it reaches the daemon: a saved point
    /// waits on the locations file, a route on reading and parsing a
    /// `.gpx`, Use My Location on a permission prompt that can sit for a
    /// minute. Without a fence, picking a trip while a route is still
    /// loading sends the trip first and the route second, and the device
    /// ends up at the choice the user *abandoned*. Per-pane
    /// serialization in the daemon does not help: it preserves arrival
    /// order, which is exactly the order that is wrong here.
    ///
    /// An action superseded **before** it dispatches sends nothing at
    /// all. One superseded after dispatch cannot be recalled: the
    /// request is already on its way and may well reach the device. What
    /// the fence then guarantees is only that it publishes nothing
    /// stale, neither a checkmark nor an alert, and the refresh that
    /// follows reconciles whatever the daemon ended up recording.
    ///
    /// It is not silent about everything. A `.gpx` that could not be
    /// read still says so, because that is a fact about the file rather
    /// than about which location won, and a broken row would otherwise
    /// look like it merely lost a race.
    private var locationIntent: UInt64 = 0

    private let paneId: String
    private weak var client: (any PaneLocationControlling)?
    private let locations: any LocationsStoring
    private let routeFiles: any RouteFileLoading
    private let makeLocationProvider: @MainActor () -> any MacLocationProviding
    /// Built on the first Use My Location click, then kept. Deferring it
    /// keeps a `CLLocationManager` out of every pane that never asks for
    /// one, and keeps `AppTests` from constructing one or reaching TCC.
    private var locationProvider: (any MacLocationProviding)?
    /// The Use My Location action in flight, so repeat clicks join it
    /// rather than each running their own set and raising their own
    /// alert. Joined rather than superseded, unlike `refreshTask`: two
    /// clicks want the same answer, not a newer one.
    ///
    /// The task captures the view model weakly, so storing it here
    /// creates no lasting cycle. Awaiting through that weak reference
    /// does pin the view model for as long as the action runs, which
    /// changes no lifetime: the caller is awaiting it across the very
    /// same span.
    private var inFlightUseMyLocation: InFlightAction?
    /// Route applications in flight, keyed by path, so a second click on
    /// the same row joins the first rather than opening the file twice
    /// and stacking two identical alerts behind it.
    ///
    /// Keyed rather than single because two *different* routes are two
    /// different choices, and each needs its own entry to be joinable.
    /// Both still start; which one reaches the device is settled by
    /// `locationIntent`, so the earlier one abandons itself rather than
    /// racing the later one to the daemon.
    private var inFlightRoutes: [String: InFlightAction] = [:]
    private var refreshTask: Task<Void, Never>?
    /// Subsystem is the app's bundle identifier, matching the daemon's
    /// `com.deviceterm.daemon`. These failures are *only* logged, so a
    /// subsystem nobody filters on would hide them completely.
    private let log = Logger(subsystem: "com.deviceterm", category: "pane-location")

    init(
        paneId: String,
        client: (any PaneLocationControlling)?,
        locations: any LocationsStoring = LocationsFileStore(),
        routeFiles: any RouteFileLoading = RouteFileReader(),
        makeLocationProvider: @escaping @MainActor () -> any MacLocationProviding = {
            CoreLocationProvider()
        }
    ) {
        self.paneId = paneId
        self.client = client
        self.locations = locations
        self.routeFiles = routeFiles
        self.makeLocationProvider = makeLocationProvider
    }

    /// Re-read the pane's location state. Returns immediately; the
    /// snapshot updates when the daemon answers.
    ///
    /// Cancels the prior task and ignores its result, so stale responses
    /// cannot land out of order. Cancellation suppresses a superseded
    /// result; it does not necessarily stop an RPC already in transport.
    ///
    /// The task captures the client and pane id strongly but the view
    /// model weakly, touching `self` only after the call returns. A
    /// `guard let self` before the `await` would defeat that: `self` owns
    /// `refreshTask`, so the task would own `self` back for the duration,
    /// and a stalled `devicectl` enumeration would keep a closed pane's
    /// view model alive for as long as the subprocess hung. Weak capture
    /// lets the view model deallocate while an RPC is in flight, so no
    /// `deinit` cancellation is required.
    func refresh() {
        guard isAvailable, let client else { return }
        refreshTask?.cancel()
        let paneId = self.paneId
        let locations = self.locations
        refreshTask = Task { @MainActor [weak self] in
            // Reads on the gate's executor, not the main actor: even a
            // small config file can stall on a network-mounted home
            // directory, and this feeds a menu.
            let saved = await locations.load()
            guard !Task.isCancelled else { return }
            self?.savedLocations = saved
            do {
                let fresh = try await client.paneLocationState(paneId: paneId)
                guard !Task.isCancelled else { return }
                self?.state = fresh
                self?.reconcileActiveRoute(with: fresh.location)
            } catch {
                // A superseded refresh must not speak on *either* path.
                // Checking only `CancellationError` isn't enough: a
                // cancelled request usually fails with whatever the
                // transport reports rather than a cancellation error, and
                // if such an error carried a terminal code it would
                // disable the menu permanently on the strength of a
                // request nobody is waiting for. Both signals are checked
                // because a `CancellationError` can also surface without
                // this task itself being marked cancelled.
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                self?.handle(error, whileDoing: "read location state")
            }
        }
    }

    /// Apply a location to the pane's device, then re-read the daemon's
    /// recorded claim.
    ///
    /// Deliberately **not** optimistic, unlike this file's sibling
    /// `SimulatorPaneViewModel.rotate`. A rotation is a local
    /// presentation change the GUI must reflect instantly to keep input
    /// mapping honest; a location is a claim about a remote device, and
    /// the daemon only records it once the backend confirms. Moving the
    /// checkmark before that would show a position the device may have
    /// rejected, an unknown scenario name being exactly that case.
    ///
    /// A coordinate is also saved to the locations file, under `label`
    /// when the user supplied one. Only coordinates: a trip and `None`
    /// are already permanent rows, so saving them would add a duplicate
    /// that never goes away. A coordinate nobody chose by hand does not
    /// come through here at all; `useMyLocation` explains why.
    ///
    /// The save happens because the user chose the place, not because
    /// the device accepted it. The file is a curated list of positions,
    /// not a log of successful sets, and a coordinate typed while a
    /// device happened to be offline should not be silently discarded.
    /// Re-picking a saved row deduplicates to nothing, so this stays
    /// idempotent.
    ///
    /// The save runs **inside this task**, ahead of the RPC, rather than
    /// in one of its own. A second task publishing `savedLocations`
    /// would be a second publication channel, and only `refresh()` is
    /// fenced (each cancels its predecessor): the two could resume in
    /// either order, so an older list could land after a newer one and
    /// drop a row the user had just saved back out of the menu, while
    /// the file on disk was perfectly correct. One writer, one
    /// publisher.
    ///
    /// Holds no strong reference to the view model across its RPC, for
    /// the same reason `refresh()` doesn't. This task isn't stored, so it
    /// forms no retain *cycle*, but promoting `self` would still pin a
    /// closed pane's view model for however long the request takes.
    func apply(_ location: SimulatedLocation, label: String? = nil) {
        guard isAvailable, let client else { return }
        let paneId = self.paneId
        let locations = self.locations
        var entry: LocationEntry?
        if case let .coordinate(latitude, longitude) = location {
            entry = .coordinate(latitude: latitude, longitude: longitude, label: label)
        }
        let saved = entry
        let intent = beginLocationIntent()
        Task { @MainActor [weak self] in
            if let saved {
                await locations.record(saved)
            }
            // Saving suspends, so even this path can be overtaken. The
            // row stays in the file either way: the user chose to save
            // it, and that is independent of which location won.
            guard self?.isCurrentIntent(intent) ?? false else { return }
            do {
                try await client.paneLocationSet(paneId: paneId, location: location)
            } catch {
                self?.handle(error, whileDoing: "set location")
            }
            // Refresh either way, and it is the only thing that writes
            // `savedLocations`. On success it confirms the daemon's
            // record; on failure it repaints the checkmark back onto the
            // daemon's last recorded claim.
            self?.refresh()
        }
    }

    /// Take this Mac's position and apply it to the pane's device.
    ///
    /// Returns an alert when acquisition fails, when the acquired
    /// position is unusable, or when an actionable apply failure occurs
    /// while the choice is still current. Returns nil on acceptance, a
    /// coalesced click, supersession, a scope refusal, a missing client,
    /// and a pane found closed before dispatch. An acquisition failure
    /// alerts even after closure; the weak view-controller caller drops
    /// what it can no longer show.
    ///
    /// Nothing here presents anything: the wording is decided by
    /// `UseMyLocationDecision` and shown by the view controller, so both
    /// halves stay testable without AppKit.
    ///
    /// Every acquisition or apply failure the user can act on alerts,
    /// including a set the device refuses. This row cannot rely on the
    /// menu's usual feedback: picking a trip or a
    /// saved row leaves a visibly unmoved checkmark next to the row just
    /// clicked, whereas a successful fix checks a matching saved row or
    /// appends a coordinate row, so its failure looks like nothing at
    /// all. Which is also why the set is awaited here rather than handed
    /// to `apply`, whose failures are only logged.
    ///
    /// Three outcomes stay silent. A **scope refusal**, already known or
    /// turning up on this call, disables the whole submenu, which is a
    /// louder and more durable answer than an alert. A **missing client**
    /// means the app is tearing down. And a **closed pane** has nobody
    /// left to tell.
    ///
    /// `isPaneLive` is re-checked after the fix arrives and before
    /// anything is sent. The wait in between is bounded by the permission
    /// timeout plus the fix itself, which is ample time for a tab to
    /// close, and a pane id outlives the tab that closed it: an orphaned
    /// sim keeps its record through
    /// `transferOwnership` and can be adopted by another session.
    /// Without the re-check, a fix answered after that adoption would
    /// set this Mac's position on a device now belonging to somebody
    /// else's tab, and the daemon would allow it, since the GUI
    /// connection is `.guiPeer` and is authorized for any live pane.
    ///
    /// **The fix is not saved to the locations file**, unlike a typed
    /// coordinate. The file is a curated list the user hand-edits and
    /// deviceterm never evicts from, and "wherever I am" is not a place
    /// somebody chose: GPS jitter moves the reading by metres between
    /// clicks, so every use would append another near-duplicate row that
    /// only a hand edit could remove. Keeping one is still a choice the
    /// user can make: picking the coordinate row a fix leaves behind
    /// goes through `apply` and saves it, as Custom Coordinates does.
    ///
    /// The coordinate is canonicalized to the file's precision anyway.
    /// The menu matches the daemon's claim by exact equality, so a fix
    /// carrying a Double's full precision could never check a row read
    /// from the file, even for the very same place. Beyond about six
    /// decimals the digits are noise on a Wi-Fi positioning fix in any
    /// case.
    ///
    /// The whole action coalesces, not just the fix. A second click
    /// joins the one already running and returns nothing, so there is
    /// one prompt, one `pane.location.set`, one refresh, and one alert
    /// however many times the row is chosen. Coalescing only the
    /// acquisition is not enough: every click would still own a set and
    /// an alert, which turns a slow or failing fix into a stack of
    /// identical modal alerts, and a menu item that looks like it did
    /// nothing is exactly the one people click again.
    func useMyLocation(isPaneLive: @escaping @MainActor () -> Bool) async -> LocationAlert? {
        if let running = inFlightUseMyLocation, isCurrentIntent(running.intent) {
            // Wait for the click that got here first, so this call ends
            // when the work does, then stay quiet: that click owns the
            // outcome and the alert that goes with it. Joining rather
            // than claiming is right *because* it is still current: this
            // is the same choice, not a newer one.
            _ = await running.task.value
            return nil
        }
        // Claimed here rather than inside the task, so the ordering
        // follows the clicks.
        let intent = beginLocationIntent()
        let task = Task { @MainActor [weak self] in
            await self?.takeAndApplyFix(isPaneLive: isPaneLive, intent: intent)
        }
        inFlightUseMyLocation = InFlightAction(intent: intent, task: task)
        let alert = await task.value
        // Only if it is still ours: a newer click has already replaced
        // the entry, and clearing it here would strand that one.
        if inFlightUseMyLocation?.intent == intent { inFlightUseMyLocation = nil }
        return alert
    }

    private func takeAndApplyFix(
        isPaneLive: @MainActor () -> Bool,
        intent: UInt64
    ) async -> LocationAlert? {
        guard isAvailable, let client else { return nil }
        let fix = await provider().currentFix()
        // The longest suspension of any row: an unanswered prompt holds
        // this for about a minute, which is ample time to give up and
        // pick something else. Checked before the outcome is even
        // examined, so a superseded request raises no alert either.
        guard isCurrentIntent(intent) else { return nil }
        guard case let .fix(latitude, longitude) = fix else {
            return UseMyLocationDecision.alert(for: fix)
        }
        let location = SimulatedLocation.coordinate(
            latitude: LocationsFileParser.canonical(latitude),
            longitude: LocationsFileParser.canonical(longitude)
        )
        // CoreLocation has an in-band invalid sentinel, and it is
        // `(-180, -180)`: a longitude that passes and a latitude that
        // does not. Catching it here keeps a sentinel from travelling as
        // a position and coming back as an `invalidParams` the user
        // cannot make sense of.
        if let defect = location.defect {
            return UseMyLocationDecision.alert(for: .unavailable(
                "Location Services returned a position DeviceTerm cannot use "
                    + "(\(defect.message))."
            ))
        }
        // Nothing to alert about: the pane the user clicked is gone, so
        // there is nobody left to tell and nothing they'd want done.
        guard isPaneLive() else { return nil }
        // Refresh either way. On success it confirms the daemon's
        // record; on failure it repaints the checkmark back onto the
        // daemon's last recorded claim.
        defer { refresh() }
        do {
            try await client.paneLocationSet(paneId: paneId, location: location)
            return nil
        } catch {
            handle(error, whileDoing: "set location")
            // A scope refusal has already disabled the whole submenu,
            // which is its own explanation; a second complaint about it
            // would be noise.
            guard isAvailable else { return nil }
            // Nor does a superseded set, for the same reason as the
            // route path: the set itself suspends, so a failure that
            // lands after the user picked something else is about a
            // choice they have already abandoned.
            guard isCurrentIntent(intent) else { return nil }
            return UseMyLocationDecision.applyFailure(reason: ErrorText.describing(error))
        }
    }

    /// Walk this pane's device along a saved `.gpx` route.
    ///
    /// Returns an alert for any route-file load failure, and for an
    /// actionable start failure while the route is still current.
    /// Returns nil on acceptance, a coalesced click, supersession after
    /// a successful load, a scope refusal, a missing client, and a pane
    /// found closed before dispatch. A load failure alerts even after
    /// supersession or closure; the weak view-controller caller drops
    /// what it can no longer show.
    ///
    /// That is the one place this parts from `useMyLocation`, which goes
    /// quiet on a superseded denial: a denial is about the choice, while
    /// an unreadable `.gpx` is about a row that stays broken whatever
    /// the user picks next.
    ///
    /// This row's checkmark behaves like any other: it moves on
    /// success and stays put on failure. What it cannot express is
    /// *why* a route did not play, and the answer is usually about the
    /// file rather than the device, so a load failure is reported
    /// directly. The file is opened, parsed, and validated off the main
    /// actor by `routeFiles`.
    ///
    /// The same three outcomes stay silent as in `useMyLocation`, for
    /// the same reasons: a scope refusal has already disabled the whole
    /// submenu, a missing client means the app is tearing down, and a
    /// closed pane has nobody left to tell.
    ///
    /// `isPaneLive` is re-checked after the file is read and before
    /// anything is sent, because reading and parsing a route of several
    /// thousand points suspends long enough for a tab to close, and a
    /// pane id outlives the tab that closed it. See `useMyLocation` for
    /// why an adopted pane makes that a real hazard rather than a
    /// theoretical one.
    func applyRoute(
        path: String,
        isPaneLive: @escaping @MainActor () -> Bool
    ) async -> LocationAlert? {
        if let running = inFlightRoutes[path], isCurrentIntent(running.intent) {
            // Wait for the click that got here first, so this call ends
            // when the work does, then stay quiet: that click owns the
            // outcome and the alert that goes with it.
            _ = await running.task.value
            return nil
        }
        // As in `useMyLocation`: claimed per click, and a click that
        // joined a still-current action claims nothing.
        let intent = beginLocationIntent()
        let task = Task { @MainActor [weak self] in
            await self?.loadAndStartRoute(path: path, isPaneLive: isPaneLive, intent: intent)
        }
        inFlightRoutes[path] = InFlightAction(intent: intent, task: task)
        let alert = await task.value
        if inFlightRoutes[path]?.intent == intent { inFlightRoutes[path] = nil }
        return alert
    }

    private func loadAndStartRoute(
        path: String,
        isPaneLive: @MainActor () -> Bool,
        intent: UInt64
    ) async -> LocationAlert? {
        guard isAvailable, let client else { return nil }
        let location: SimulatedLocation
        do {
            location = try await routeFiles.load(path: path)
        } catch let error as RouteFileError {
            return RouteFileDecision.alert(for: error, path: path)
        } catch {
            return RouteFileDecision.alert(
                for: .unreadable(message: ErrorText.describing(error)),
                path: path
            )
        }
        // Reading and parsing a route of several thousand points is the
        // suspension most likely to be overtaken by an impatient second
        // choice. A load *failure* still alerts above, because that is
        // about the file rather than about which location wins.
        guard isCurrentIntent(intent) else { return nil }
        // Nothing to alert about: the pane the user clicked is gone, so
        // there is nobody left to tell and nothing they'd want done.
        guard isPaneLive() else { return nil }
        // Refresh either way. On success it confirms the daemon's
        // record; on failure it repaints the checkmark back onto the
        // daemon's last recorded claim.
        defer { refresh() }
        do {
            try await client.paneLocationSet(paneId: paneId, location: location)
            // Checked again on the way out, not just on the way in. The
            // set itself suspends, so a choice made while it was in
            // flight is newer than this one, and publishing here would
            // put the checkmark on a route the user has moved past until
            // the next refresh happened to correct it.
            guard isCurrentIntent(intent) else { return nil }
            // Recorded only on success, and only after the daemon has
            // taken it, so a refused route leaves the checkmark where
            // the device actually is.
            activeRoute = (path: path, location: location)
            return nil
        } catch {
            handle(error, whileDoing: "start route")
            // A scope refusal has already disabled the whole submenu,
            // which is its own explanation; a second complaint about it
            // would be noise.
            guard isAvailable else { return nil }
            // Nor does a superseded set get to raise a modal alert about
            // a route the user has already replaced.
            guard isCurrentIntent(intent) else { return nil }
            return RouteFileDecision.startFailure(reason: ErrorText.describing(error))
        }
    }

    /// Drop the remembered route once the daemon's claim is no longer the
    /// one that route produced.
    ///
    /// Compares the whole location rather than just "is it still a
    /// route", so picking a *different* route, a trip, a point, or None
    /// all release the checkmark, and so does a claim the daemon dropped
    /// on its own (a transfer, a shutdown).
    private func reconcileActiveRoute(with claim: SimulatedLocation?) {
        if activeRoute?.location != claim { activeRoute = nil }
    }

    /// Claim the newest intent, superseding anything still in flight.
    ///
    /// Called once per user choice, at the click rather than at
    /// dispatch, so the ordering the fence enforces is the order the
    /// rows were picked in.
    private func beginLocationIntent() -> UInt64 {
        locationIntent &+= 1
        return locationIntent
    }

    /// Whether `intent` is still the user's latest choice.
    private func isCurrentIntent(_ intent: UInt64) -> Bool {
        intent == locationIntent
    }

    /// The cached provider, constructing it on first use.
    private func provider() -> any MacLocationProviding {
        if let locationProvider { return locationProvider }
        let created = makeLocationProvider()
        locationProvider = created
        return created
    }

    /// Classify a daemon error. A scope refusal is permanent, so it
    /// disables the surface instead of being retried on every menu
    /// open; anything else is treated as transient and only logged, so
    /// a momentary failure leaves the last good snapshot in place.
    private func handle(_ error: any Error, whileDoing action: String) {
        if case let DaemonClientError.daemon(code, _) = error,
            code == Self.scopeViolationCode || code == Self.unauthorizedCode {
            isAvailable = false
            log.info("location unavailable on this connection; disabling the menu")
            return
        }
        log.error("couldn't \(action, privacy: .public): \(ErrorText.describing(error), privacy: .public)")
    }
}
