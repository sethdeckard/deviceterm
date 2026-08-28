// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import os
import Sparkle

/// Narrates the stages Sparkle reports to the driver. Shares the category
/// with `UpdateController`'s logger so one predicate covers the whole check.
private let updateLog = Logger(subsystem: "com.deviceterm", category: "update")

/// Deviceterm's custom Sparkle `SPUUserDriver`, mapping
/// every update stage to the unobtrusive `UpdateViewModel` pill instead of
/// Sparkle's default modal windows. Drives the pill directly, including
/// inline and downloaded release notes.
@MainActor
final class UpdateUserDriver: NSObject, SPUUserDriver {
    /// Invoked when Sparkle asks for the current update to be brought into
    /// focus. The driver owns no window, so the controller supplies the
    /// re-presentation.
    var onRevealRequested: () -> Void = {}

    private let viewModel: UpdateViewModel
    /// The configured policy, so an auto (non-user-initiated) permission
    /// request is answered without a Sparkle prompt.
    private let policyProvider: () -> AutoUpdatePolicy

    private var expectedLength: UInt64 = 0
    private var receivedLength: UInt64 = 0
    /// The download's cancellation closure, retained so progress updates
    /// keep the pill's cancel affordance working (Sparkle only hands it
    /// over once, in `showDownloadInitiated`).
    private var downloadCancellation: () -> Void = {}
    /// The available update's version + reply, retained so downloaded
    /// (linked) release notes can refresh the pill without a fresh
    /// `showUpdateFound`.
    private var availableVersion: String?
    private var availableReply: ((SPUUserUpdateChoice) -> Void)?

    init(viewModel: UpdateViewModel, policyProvider: @escaping () -> AutoUpdatePolicy) {
        self.viewModel = viewModel
        self.policyProvider = policyProvider
    }

    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        // We drive checks from the `auto-update` config, so this prompt
        // shouldn't normally appear; answer it from the policy and never
        // send a system profile.
        let checks = policyProvider() != .off
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: checks, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        updateLog.notice("user-initiated check started")
        viewModel.set(.checking(cancel: cancellation))
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        let version = appcastItem.displayVersionString
        updateLog.notice("presenting update \(version, privacy: .public)")
        availableVersion = version
        availableReply = reply
        // Inline release notes (the appcast `<description>`) are available
        // now; linked notes arrive later via showUpdateReleaseNotes.
        setUpdateAvailable(version: version, notes: appcastItem.itemDescription, reply: reply)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // Linked notes finished downloading, so refresh the popover content,
        // keeping the same version + reply from showUpdateFound.
        guard let version = availableVersion, let reply = availableReply else { return }
        let notes = String(data: downloadData.data, encoding: .utf8)
        setUpdateAvailable(version: version, notes: notes, reply: reply)
    }

    private func setUpdateAvailable(
        version: String,
        notes: String?,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        viewModel.set(.updateAvailable(
            version: version,
            notes: notes,
            install: { reply(.install) },
            dismiss: { reply(.dismiss) }
        ))
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        // The pill keeps the inline notes from the appcast, so this is a
        // downgrade in detail rather than a failure worth showing.
        updateLog.notice(
            "release notes download failed: \(ErrorText.describing(error), privacy: .public)"
        )
    }

    func showUpdateNotFoundWithError(
        _ error: Error,
        acknowledgement: @escaping () -> Void
    ) {
        updateLog.notice("check finished with no update")
        // Auto-acknowledge so nothing blocks; the pill auto-dismisses.
        viewModel.set(.notFound(dismiss: { [weak self] in self?.viewModel.reset() }))
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        updateLog.error("update failed: \(ErrorText.describing(error), privacy: .public)")
        viewModel.set(.error(
            message: error.localizedDescription,
            dismiss: { [weak self] in self?.viewModel.reset() }
        ))
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        updateLog.notice("download started")
        expectedLength = 0
        receivedLength = 0
        downloadCancellation = cancellation
        viewModel.set(.downloading(fraction: nil, cancel: cancellation))
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedLength += length
        let fraction = expectedLength > 0 ? Double(receivedLength) / Double(expectedLength) : nil
        viewModel.set(.downloading(fraction: fraction, cancel: downloadCancellation))
    }

    func showDownloadDidStartExtractingUpdate() {
        viewModel.set(.extracting(fraction: 0))
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        viewModel.set(.extracting(fraction: progress))
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        updateLog.notice("ready to install")
        // Actionable pill: the user clicks Restart to install + relaunch.
        // If they don't, Sparkle installs on next quit.
        viewModel.set(.readyToInstall(install: { reply(.install) }))
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        updateLog.notice(
            "installing (terminated=\(applicationTerminated, privacy: .public))"
        )
    }

    func showUpdateInstalledAndRelaunched(
        _ relaunched: Bool,
        acknowledgement: @escaping () -> Void
    ) {
        updateLog.notice("installed (relaunched=\(relaunched, privacy: .public))")
        viewModel.reset()
        acknowledgement()
    }

    /// Sparkle calls this when the user requests another check while update UI
    /// is already presented. Retry presentation in case the pill is not
    /// attached to a window.
    func showUpdateInFocus() {
        updateLog.notice("asked to bring the current update into focus")
        onRevealRequested()
    }

    func dismissUpdateInstallation() {
        viewModel.reset()
    }
}
