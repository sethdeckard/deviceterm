// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// The data shape returned by read-only intents. Wraps the wire
/// payload types from DaemonProtocol so the GUI's source layer
/// (`AppCommandSubscriber`) can JSON-encode them directly into
/// `AppCommandResult.data` without an intermediate translation.
enum IntentResponse: Sendable, Equatable {
    case workspaceWindows([WorkspaceWindow])
    case workspaceWindow(WorkspaceWindowDetail)
    case workspaceTabs([WorkspaceTab])
    case workspaceTab(WorkspaceTabDetail)
    case workspacePanes([WorkspacePane])
    case workspacePane(WorkspacePane)
    case workspaceMutation(WorkspaceMutationReceipt)
    case workspaceCapture(WorkspaceCaptureResult)
}
