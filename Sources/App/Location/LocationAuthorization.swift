// SPDX-License-Identifier: GPL-3.0-or-later

/// The authorization states the provider distinguishes: the permission state
/// machine behind Device ▸ Location ▸ Use My Location, held apart from
/// CoreLocation so it can be tested.
///
/// `CoreLocationProvider` translates `CLAuthorizationStatus` into these
/// cases and carries out whichever step they name. What lives here is the
/// permission rule: given a status and how far a request has got, what
/// happens next. Readiness, timeout fallbacks, and sharing one request
/// between callers stay with the provider, since they are about driving
/// the framework rather than about permission.
///
/// Separating the permission transitions from the framework driving is
/// what makes these timing rules testable on their own.
enum LocationAuthorization: Equatable, Sendable {
    case notDetermined
    case allowed
    case denied
    case restricted
    /// A `CLAuthorizationStatus` this build does not recognize.
    case unrecognized

    /// What to do when a request begins in this state.
    var startingStep: LocationAuthorizationStep {
        switch self {
        case .notDetermined:
            return .requestAuthorization

        case .allowed:
            return .requestLocation

        default:
            return settled
        }
    }

    /// What to do when a status report arrives while a request is
    /// already waiting for the user's answer.
    ///
    /// It differs from `startingStep` in exactly one case, and that case
    /// is a large part of why this type exists: `notDetermined` means
    /// keep waiting. It is neither an answer nor a reason to ask again.
    ///
    /// The status is what distinguishes the two, because ordering
    /// cannot. CoreLocation's reports reach the main actor the same way
    /// every other callback does, so one can land after the request that
    /// followed it. `notDetermined` is the state a request asks *from*,
    /// so it can never be an answer to it: while authorization is
    /// pending it means keep waiting for a settled status.
    var waitingStep: LocationAuthorizationStep {
        switch self {
        case .notDetermined:
            return .keepWaiting

        case .allowed:
            return .requestLocation

        default:
            return settled
        }
    }

    /// The outcome for a state that answers the question either way, so
    /// the two steps above agree on it by construction.
    private var settled: LocationAuthorizationStep {
        switch self {
        case .denied:
            return .finish(.denied)

        case .restricted:
            return .finish(.restricted)

        default:
            return .finish(.unavailable(
                "Location Services reported a permission state DeviceTerm does not know."
            ))
        }
    }

    /// What to do about a status report, given where the request has
    /// got to. Total, so every combination has a decided answer rather
    /// than an implicit one.
    func step(reportedIn phase: LocationRequestPhase) -> LocationAuthorizationStep {
        switch phase {
        case .idle, .awaitingFix:
            // Nothing is waiting on permission, so the report is not an
            // answer to anything. Noting that the manager is ready is
            // all it is good for.
            return .keepWaiting

        case .awaitingReady:
            return startingStep

        case .awaitingAuthorization:
            return waitingStep
        }
    }
}
