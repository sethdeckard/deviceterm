// SPDX-License-Identifier: GPL-3.0-or-later
//
// DiagnosticKind: log-safe names for the errors the attach path can fail with.
//
// Error payloads can contain identifiers or caller text: `PhysicalDeviceError`
// carries a device UDID in every case, and `PaneError` carries pane ids,
// UDIDs, and caller-supplied text. Log an identifier-free kind instead, and use
// the attach id for correlation.
//
// Both mappings are exhaustive `switch`es on purpose: adding a case to either
// error stops compiling here, so a new failure mode has to be given a name
// rather than defaulting into something that prints its payload.

extension PhysicalDeviceError {
    /// A short, identifier-free name for this failure, safe to log `.public`.
    var diagnosticKind: String {
        switch self {
        case .notConnected:
            return "not-connected"

        case .tunnelBringUpFailed:
            return "tunnel-bring-up-failed"

        case .serviceCatalogUnavailable:
            return "service-catalog-unavailable"

        case let .missingService(_, service):
            // A role label ("human input"), not caller data and not a device
            // identifier, so it earns its place in the line.
            return "missing-service:\(service)"

        case .tooOldToMirror:
            return "too-old-to-mirror"
        }
    }
}

extension PaneError {
    /// A short, identifier-free name for this failure, safe to log `.public`.
    var diagnosticKind: String {
        switch self {
        case .notFound:
            return "pane-not-found"

        case .deviceNotFound:
            return "device-not-found"

        case .malformedUDID:
            return "malformed-udid"

        case .startStreamFailed:
            return "start-stream-failed"

        case .paneNotActive:
            return "pane-not-active"

        case .hidUnavailable:
            return "hid-unavailable"

        case let .bridgeFailed(_, operation, _):
            // `operation` is a fixed verb from the daemon's own vocabulary
            // (`touch`, `rotate`, …), never caller-supplied text, and knowing
            // which verb failed is most of the diagnostic value. `.label`, not
            // the interpolated case, is the text clients read.
            return "bridge-failed:\(operation.label)"

        case .unsupportedCharacter:
            return "unsupported-character"

        case .unsupportedKeyCode:
            return "unsupported-key-code"

        case let .unsupportedOperation(_, operation):
            return "unsupported-operation:\(operation.label)"

        case .unknownLocationScenario:
            return "unknown-location-scenario"

        case .shortIDExhausted:
            return "short-id-exhausted"

        case .paneAlreadyAttached:
            return "pane-already-attached"

        case .inputNotQuiesced:
            return "input-not-quiesced"

        case .ownerNotReady:
            return "owner-not-ready"
        }
    }
}
