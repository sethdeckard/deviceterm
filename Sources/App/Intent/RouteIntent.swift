// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// Source-agnostic, typed value describing what an external caller wants the
/// app to do.
///
/// This is the boundary type between a caller and the GUI's `Router`.
/// CLI verbs arrive over the daemon back-channel and are translated by
/// `CLIIntentTranslator`. `IntentDispatcher` is the single consumer that
/// resolves raw refs, validates, and either synthesizes a `Route` for the
/// Router to execute or reads from the workspace directly.
///
/// Why a separate enum from `Route`: `Route` uses the internal monotonic IDs
/// the Router mints. `RouteIntent` preserves public refs as raw strings so the
/// GUI can resolve them against one live snapshot.
enum RouteIntent: Sendable, Equatable {
    case workspaceWindowList(all: Bool)
    case workspaceWindowShow(String?)
    case workspaceWindowOpen
    case workspaceWindowFocus(String?)
    case workspaceWindowClose(String?, mode: WorkspaceCloseMode)

    case workspaceTabList(window: String?, all: Bool)
    case workspaceTabShow(String?)
    case workspaceTabOpen(window: String?, cwd: String?, command: [String]?)
    case workspaceTabFocus(String?)
    case workspaceTabClose(String?, mode: WorkspaceCloseMode)
    case workspaceTabRename(String?, name: String?)
    case workspaceTabMove(String?, window: String, index: Int?)
    case workspaceTabProtect(String?, protected: Bool)

    case workspacePaneList(tab: String?)
    case workspacePaneShow(String?)
    case workspacePaneSplit(String?, direction: WorkspaceSplitDirection)
    case workspacePaneFocus(String?)
    case workspacePaneClose(String?, mode: WorkspaceCloseMode?)
    case workspacePaneRename(String?, name: String?)
    case workspacePaneSendInput(String, text: String, typeDelayMs: Int?)
    case workspacePaneCaptureText(String, ansi: Bool)

    /// Claim an unlinked sim: the `.sim` arm of `device attach <ref>`.
    /// The udid must currently have no live linked session (external sim
    /// or sim left over from a closed agent tab); on success a fresh pane
    /// record is bound to the calling session.
    case paneAttach(
        udid:
        String
        )

    /// Mount a physically-connected device: the `.device` arm of
    /// `device attach <ref>`, and the shim's contextual auto-attach.
    /// `deviceId` is the device's stable CoreDevice UDID. This is the request
    /// path for mirroring a device into the caller's current tab, either
    /// fresh or by moving an existing mirror (`relinkExisting`). The
    /// workspace restoring a pane of its own that dropped does not come
    /// through here, because helper-restart recovery and the resurrect watch
    /// dispatch their own routes. `relinkExisting`
    /// moves the mirror here when the device is already shown in another
    /// tab (set by the shim's contextual trigger); when false, an attach
    /// against a device mirrored elsewhere is rejected.
    case devicePaneAttach(
        deviceId: String,
        relinkExisting: Bool
        )
}
