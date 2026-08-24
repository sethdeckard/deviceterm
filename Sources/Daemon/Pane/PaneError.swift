// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
import DaemonProtocol
import Foundation
import IOSurface
import os
import SurfaceTrace

public enum PaneError: Error, Equatable, Sendable {
    /// A re-attach whose requester has already issued a newer one. Only
    /// reachable when the daemon handles two of one requester's attaches out
    /// of order, so the caller seeing it has already moved on.
    case staleAttach(
        paneId:
        UUID
        )
    case notFound(
        paneId:
        UUID
        )
    case deviceNotFound(
        udid:
        String
        )
    case malformedUDID(
        udid:
        String
        )
    case startStreamFailed(
        udid:
        String,
        message: String
        )
    /// Caller asked for an input or AX operation on a pane whose
    /// underlying sim has been shut down. The pane record stays
    /// around (so the GUI can show its shutdown overlay) but the
    /// bridge clients are gone: there's nothing to send the event
    /// to.
    case paneNotActive(
        paneId:
        UUID
        )
    /// HID / PurpleHID acquisition failed at `pane.create` time.
    /// Surfacing here (rather than per-input-call lazily) keeps the
    /// failure mode visible to the caller before they wire the
    /// pane into a tab.
    case hidUnavailable(
        udid:
        String,
        message: String
        )
    /// A bridge HID send returned an error. The pane is otherwise
    /// alive; the caller can retry or abandon.
    case bridgeFailed(
        paneId:
        UUID,
        operation: PaneOperation,
        message: String
        )
    /// `pane.input.text` got a character outside the daemon's ASCII
    /// translation table. Carries the offending character so the
    /// caller knows exactly which char to filter or split out.
    case unsupportedCharacter(
        paneId:
        UUID,
        character: Character
        )
    /// `pane.input.key` got a kVK virtual key code outside the
    /// daemon's translation table. Mostly indicates a caller
    /// outside the ANSI layout (international keys, F13+, keypad,
    /// media keys). The table covers the ANSI layout only.
    case unsupportedKeyCode(
        paneId:
        UUID,
        keyCode: UInt32
        )
    /// The pane's backend doesn't support this verb, e.g. Crown or
    /// accessibility on a backend that has no such hardware/service.
    /// Carries the operation so its fixed label tells the caller which verb
    /// was rejected. Maps to `invalidParams` (the request can't be
    /// fulfilled against this pane as posed).
    case unsupportedOperation(
        paneId:
        UUID,
        operation: PaneOperation
        )
    /// A scenario rejected by the simulator backend because
    /// CoreSimulator silently accepts unknown names, so an unchecked typo
    /// would look like it worked. Carries the offending name, like
    /// `unsupportedCharacter` / `unsupportedKeyCode`. Maps to
    /// `invalidParams`.
    case unknownLocationScenario(
        paneId:
        UUID,
        name: String
        )
    /// `ShortID.maxMintAttempts` collisions while assigning a pane
    /// short_id. Vanishingly improbable at this scale (32^6 ≈ 1B values,
    /// expected concurrent panes in single digits); surfaces a buggy
    /// RNG or pathological saturation as a clean `serverError` instead
    /// of looping the actor.
    case shortIDExhausted
    /// `createSim` was called for a UDID that already has a live pane
    /// record under a *different* session. The locked linkage design
    /// reserves cross-session pane movement to the human (GUI drag);
    /// daemon-side cross-session create is a hard reject so racing
    /// callers can't stack duplicates or steal a sim out from under
    /// the owning session. Same-session repeats return the existing
    /// pane's handle. See `createSim`'s dedup branch.
    case paneAlreadyAttached(
        udid:
        String,
        ownerSessionId: UUID
        )
    /// An ownership transfer (adoption) couldn't release the prior owner's
    /// held input: a release send failed, so the device can't be
    /// guaranteed input-clean. The transfer is aborted (ownership stays put)
    /// rather than flipping onto a device that may still hold a prior
    /// finger/key/button down. The caller can retry.
    case inputNotQuiesced(
        paneId:
        UUID
        )
    /// A pane create / re-attach / adoption reached its ownership commit but
    /// the target session was no longer `.ready` at the incarnation the caller
    /// captured: it was torn down (or reincarnated) between the handler's
    /// validation and the commit. The coordinator refuses to create, re-admit,
    /// or transfer a pane to a session that isn't live at that incarnation, so
    /// a delayed create can't resurrect a swept pane or mint one after a close.
    /// Retryable.
    case ownerNotReady(
        sessionId:
        UUID
        )

    /// Translate a backend-level error into the wire-facing `PaneError`,
    /// adding the paneId context the backend doesn't carry. `operation` is
    /// the calling verb, surfaced on `.unsupportedEdgeGesture` so the wire
    /// names the verb the caller actually invoked (e.g. `edgeTouch`, not a
    /// hardcoded sibling), and on `.locationCommandFailed` so a command
    /// that failed while running names its own verb. *Acquisition*
    /// failures instead keep a dedicated fixed label (`ax.acquire`,
    /// `location.acquire`) because only acquisition produces them, as
    /// does `location.enumerate` for unreadable scenario output. Shared
    /// by the input-synthesis, accessibility, and location paths.
    static func mapBackendError(
        _ error: DeviceBackendError,
        paneId: UUID,
        operation: PaneOperation
    ) -> PaneError {
        switch error {
        case .notActive:
            return .paneNotActive(paneId: paneId)

        case let .accessibilityUnavailable(message):
            return .bridgeFailed(paneId: paneId, operation: .axAcquire, message: message)

        case .unsupportedEdgeGesture, .unsupportedLocation:
            return .unsupportedOperation(paneId: paneId, operation: operation)

        case let .locationUnavailable(message):
            // Acquisition specifically, so the label is fixed, the same
            // treatment `accessibilityUnavailable` gets.
            return .bridgeFailed(paneId: paneId, operation: .locationAcquire, message: message)

        case let .locationCommandFailed(message):
            // A command that failed while running, so it reports the verb
            // the caller actually invoked. Labelling this `location.acquire`
            // would tell a client the acquisition failed for an operation
            // that got past acquisition fine.
            return .bridgeFailed(paneId: paneId, operation: operation, message: message)

        case let .locationOutputMalformed(message):
            // Only enumeration produces this, so the label is fixed.
            return .bridgeFailed(paneId: paneId, operation: .locationEnumerate, message: message)

        case let .unknownLocationScenario(name):
            return .unknownLocationScenario(paneId: paneId, name: name)
        }
    }
}
