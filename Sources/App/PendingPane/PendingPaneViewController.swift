// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DaemonProtocol
import Observation
import SwiftUI

/// The lightweight AppKit host for a
/// placeholder pane (attach in flight, or failed-awaiting-Retry). It
/// owns no daemon subscription, no Metal view, no drag host: it just
/// hosts `PendingPaneView` and flips its `@Observable` model when the
/// reconcile pass pushes a new `PendingPaneState`. Once the attach
/// succeeds the Router swaps the `.pending` leaf for the real
/// `.sim`/`.device` leaf, and `TabContentViewController` builds the
/// genuine `SimulatorPaneViewController` in this VC's place.
///
/// `family` is read by `PaneLayoutViewController.leafMetric` /
/// `minThickness` to size the pending leaf with the same metrics the
/// real pane will take, so the success swap doesn't resize the split.
@MainActor
final class PendingPaneViewController: NSViewController {
    let pendingId: PendingPaneID
    /// Coarse device family (wire string) for the layout controller's
    /// pending-leaf sizing. `.unknown` → phone-default metrics.
    let family: String
    /// Forwarded to the Router via `Route.retryPendingPane` /
    /// `Route.bootPendingPane` / `Route.cancelPendingPane`; set by the
    /// reconcile wiring.
    var onRetry: (() -> Void)?
    var onBoot: (() -> Void)?
    var onCancel: (() -> Void)?

    private let model: PendingPaneViewModel

    init(pending: PendingPaneState) {
        self.pendingId = pending.id
        self.family = pending.family ?? DeviceFamily.unknown.rawValue
        self.model = PendingPaneViewModel(
            phase: pending.phase,
            label: Self.label(for: pending)
        )
        super.init(nibName: nil, bundle: nil)
        model.onRetry = { [weak self] in self?.onRetry?() }
        model.onBoot = { [weak self] in self?.onBoot?() }
        model.onCancel = { [weak self] in self?.onCancel?() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    /// Shown label: the caller's name when present, else the device name
    /// looked up for a caller that gave none (the CLI-claim path), else a
    /// target-prefix placeholder until that lookup answers.
    static func label(for pending: PendingPaneState) -> String {
        if let displayName = pending.displayName { return displayName }
        if let resolvedLabel = pending.resolvedLabel { return resolvedLabel }
        switch pending.target {
        case let .sim(udid):
            return "Sim \(udid.prefix(8))"

        case let .device(deviceId):
            return "Device \(deviceId.prefix(8))"
        }
    }

    override func loadView() {
        view = NSHostingView(rootView: PendingPaneView(model: model))
    }

    /// Push the latest pending state: the phase may have flipped, and a
    /// looked-up device name may have replaced the target-prefix label.
    func update(pending: PendingPaneState) {
        model.phase = pending.phase
        model.label = Self.label(for: pending)
    }

    /// Drop the placeholder, cancelling the attach when one is still in
    /// flight and clearing the error when the phase is `.failed`. The
    /// same thing the placeholder's own Close button does, called when
    /// ⌘W resolves to a focused pending pane, which has no other way to
    /// reach that button from the keyboard.
    func cancelAttach() {
        onCancel?()
    }
}
