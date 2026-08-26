// SPDX-License-Identifier: GPL-3.0-or-later

import CoreLocation
import Foundation

/// The app's only CoreLocation client.
///
/// Quarantined to one file for the reason `CoreSimulatorBridge`
/// quarantines private selectors: everything above it deals in plain
/// degrees, so nothing else reasons about `CLLocationManager`'s delegate
/// lifecycle or about TCC. The daemon links CoreLocation nowhere at all.
/// The GUI resolves the fix and the wire carries two numbers, the same
/// split the saved-locations file uses.
///
/// The permission rules live in `LocationAuthorization`, where their
/// timing can be tested without CoreLocation. What stays here is what
/// needs the framework in front of it: when the manager counts as ready,
/// what a lapsed timer falls back to, and how concurrent callers share
/// one request.
///
/// Built lazily on the first Use My Location click, so opening a pane
/// neither constructs a manager nor puts the app near the authorization
/// prompt, and `AppTests` never reaches this file.
@MainActor
final class CoreLocationProvider: NSObject, MacLocationProviding, CLLocationManagerDelegate {
    /// Info.plist key macOS requires before it will show the prompt.
    /// Absent, `requestWhenInUseAuthorization()` does nothing at all and
    /// no delegate callback ever arrives, so this is checked up front
    /// rather than waited on.
    private static let usageDescriptionKey = "NSLocationWhenInUseUsageDescription"

    /// How long to wait for a new manager's first status report. Syncing
    /// with the location daemon is quick, so this only has to outlast
    /// that.
    private static let readyTimeout = Duration.seconds(5)

    /// Caps the wait for an answer to the permission prompt, so a
    /// question that is never answered cannot leave the provider pending
    /// indefinitely.
    ///
    /// Answering after it lapses is not lost work: macOS records the
    /// permission either way, so the next click finds it settled and goes
    /// straight to asking for a position.
    private static let authorizationTimeout = Duration.seconds(60)

    private let manager = CLLocationManager()
    /// Everyone waiting on the current request. `finish` resumes them
    /// all at once and empties the list, so a late second delegate
    /// callback resumes nobody.
    private var waiters: [CheckedContinuation<MacLocationFix, Never>] = []
    private var phase: LocationRequestPhase = .idle
    /// True once the manager has reported a status, which is how it
    /// signals that it has synced with the location daemon. See
    /// `LocationRequestPhase.awaitingReady` for why nothing may happen
    /// before that.
    private var isReady = false
    private var timeout: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        // The user asked for "my location", so ask for the accuracy that
        // phrase implies. On a Mac the fix comes from Wi-Fi positioning
        // either way, so this costs a moment, not a radio.
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    private static func authorization(for status: CLAuthorizationStatus) -> LocationAuthorization {
        switch status {
        case .notDetermined:
            return .notDetermined

        case .authorizedAlways, .authorizedWhenInUse:
            return .allowed

        case .denied:
            return .denied

        case .restricted:
            return .restricted

        @unknown default:
            return .unrecognized
        }
    }

    /// A position, or why there isn't one.
    ///
    /// A second call while one is in flight joins it: one prompt, one
    /// answer, handed to everyone waiting. A menu item that appears to do
    /// nothing is one people click again, so repeat calls must not turn
    /// into repeat requests or repeat failures.
    func currentFix() async -> MacLocationFix {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            guard waiters.count == 1 else { return }
            start()
        }
    }

    private func start() {
        guard Bundle.main.object(forInfoDictionaryKey: Self.usageDescriptionKey) != nil else {
            // Without the usage description macOS shows no prompt and
            // sends no callback, so this reports rather than waits on
            // something that will never arrive. A bare binary is the
            // usual way to get here; an incomplete bundle does it too.
            finish(.unavailable(
                "This copy of DeviceTerm has no location usage description, so macOS "
                    + "cannot ask permission to use your location. Launch a complete "
                    + "DeviceTerm.app bundle."
            ))
            return
        }
        guard isReady else {
            // Let the manager speak first. Reading its status or asking
            // for permission before it has synced is unreliable, and the
            // request can be dropped with no prompt and no callback.
            phase = .awaitingReady
            armTimeout(Self.readyTimeout)
            return
        }
        perform(Self.authorization(for: manager.authorizationStatus).startingStep)
    }

    private func perform(_ step: LocationAuthorizationStep) {
        switch step {
        case .requestAuthorization:
            phase = .awaitingAuthorization
            armTimeout(Self.authorizationTimeout)
            manager.requestWhenInUseAuthorization()

        case .requestLocation:
            // No timer: `requestLocation` reports its own failure rather
            // than waiting indefinitely.
            phase = .awaitingFix
            cancelTimeout()
            manager.requestLocation()

        case .keepWaiting:
            break

        case let .finish(fix):
            finish(fix)
        }
    }

    /// Resolve the request for everyone waiting on it. A no-op once
    /// something has already answered, so the delegate callbacks need no
    /// ordering guarantee between them.
    private func finish(_ fix: MacLocationFix) {
        guard !waiters.isEmpty else { return }
        let resuming = waiters
        waiters = []
        phase = .idle
        cancelTimeout()
        for waiter in resuming {
            waiter.resume(returning: fix)
        }
    }

    private func armTimeout(_ duration: Duration) {
        cancelTimeout()
        timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.timeoutExpired()
        }
    }

    private func cancelTimeout() {
        timeout?.cancel()
        timeout = nil
    }

    private func timeoutExpired() {
        switch phase {
        case .awaitingReady:
            // The manager never reported. Carry on with whatever status
            // it has: no worse than giving up, and the authorization
            // timeout still sits behind this.
            isReady = true
            perform(Self.authorization(for: manager.authorizationStatus).startingStep)

        case .awaitingAuthorization:
            finish(.notDetermined)

        case .idle, .awaitingFix:
            break
        }
    }

    private func authorizationDidChange(to status: CLAuthorizationStatus) {
        isReady = true
        perform(Self.authorization(for: status).step(reportedIn: phase))
    }

    // MARK: - CLLocationManagerDelegate
    //
    // `CLLocationManagerDelegate` carries no actor annotation, so these
    // witnesses are `nonisolated` and hop back on. A `Task` rather than
    // `MainActor.assumeIsolated`: the callbacks do arrive on the main
    // thread here (the manager is created on it), but `assumeIsolated`
    // traps when that ever stops being true, and a trap in library code
    // is exactly what the house rules reserve for `main.swift`. The hop
    // is what lets one status report overtake another, which
    // `LocationAuthorization` is written to survive.

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.authorizationDidChange(to: status)
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        // `requestLocation` delivers the single best fix it managed, so
        // the last element is the one to use.
        let coordinate = locations.last?.coordinate
        Task { @MainActor [weak self] in
            guard let coordinate else {
                self?.finish(.unavailable("Location Services returned no position."))
                return
            }
            self?.finish(.fix(latitude: coordinate.latitude, longitude: coordinate.longitude))
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: any Error
    ) {
        let isDenied = (error as? CLError)?.code == .denied
        let description = ErrorText.describing(error)
        Task { @MainActor [weak self] in
            self?.finish(isDenied ? .denied : .unavailable(description))
        }
    }
}
