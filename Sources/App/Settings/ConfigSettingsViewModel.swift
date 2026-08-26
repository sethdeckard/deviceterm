// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation

/// Drives "deviceterm > Settings…". Opens the
/// config file in a new terminal tab running `$EDITOR` (Philosophy #1
/// "the tab is the workspace", #5 "agents speak CLI"). When the file
/// doesn't exist yet, surface a create-confirmation first; on confirm,
/// write a seeded, self-documenting config, then open it.
///
/// Presentation state only: `isConfirmingCreate` toggles the SwiftUI
/// prompt (`ConfigCreatePromptView`). The actual tab launch is an
/// injected side effect (`openInEditorTab`, supplied by `AppDelegate`),
/// so this view model is testable without a live window/router.
@MainActor
@Observable
final class ConfigSettingsViewModel {
    /// True while the "Create a config file?" prompt should be shown.
    private(set) var isConfirmingCreate = false

    private let configPath: String
    private let openInEditorTab: @MainActor () -> Void
    /// Fired after the create prompt is resolved (Create or Cancel) so
    /// the host window controller can close. Never fires on the direct
    /// open path, which shows no prompt.
    private let onPromptResolved: (@MainActor () -> Void)?

    init(
        configPath: String = ConfigFile.defaultPath,
        openInEditorTab: @escaping @MainActor () -> Void,
        onPromptResolved: (@MainActor () -> Void)? = nil
    ) {
        self.configPath = configPath
        self.openInEditorTab = openInEditorTab
        self.onPromptResolved = onPromptResolved
    }

    /// Entry point for the Settings… menu action. Opens the config in an
    /// editor tab; if the file doesn't exist yet, asks first.
    func open() {
        if FileManager.default.fileExists(atPath: configPath) {
            openInEditorTab()
        } else {
            isConfirmingCreate = true
        }
    }

    /// "Create & Open": write a seeded, self-documenting config (every
    /// recognized key as a commented example), then open it.
    func confirmCreate() {
        let file = ConfigFile(path: configPath)
        file.seedDocumentedExamples()
        try? file.save()
        isConfirmingCreate = false
        openInEditorTab()
        onPromptResolved?()
    }

    /// "Cancel": dismiss the create prompt without writing or opening.
    func cancel() {
        isConfirmingCreate = false
        onPromptResolved?()
    }
}
