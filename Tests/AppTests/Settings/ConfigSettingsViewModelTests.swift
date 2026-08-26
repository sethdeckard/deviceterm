// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Foundation
import Testing

/// ConfigSettingsViewModel: the Settings… flow, exercised against a
/// temp config path with a spy for the editor-tab side effect so no
/// window/router/editor is launched.
@MainActor
struct ConfigSettingsViewModelTests {
    private func tempConfigPath() -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("deviceterm-cfg-\(UUID().uuidString)")
        return (dir as NSString).appendingPathComponent("config")
    }

    private func cleanup(_ path: String) {
        try? FileManager.default.removeItem(
            atPath: (path as NSString).deletingLastPathComponent
        )
    }

    @Test
    func existingFileOpensWithoutPrompt() throws {
        let path = tempConfigPath()
        defer { cleanup(path) }
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: path, contents: Data("# x\n".utf8))

        var opened = 0
        let viewModel = ConfigSettingsViewModel(configPath: path) { opened += 1 }
        viewModel.open()

        #expect(viewModel.isConfirmingCreate == false)
        #expect(opened == 1)
    }

    @Test
    func missingFilePromptsThenSeedsAndOpensOnConfirm() throws {
        let path = tempConfigPath()
        defer { cleanup(path) }

        var opened = 0
        let viewModel = ConfigSettingsViewModel(configPath: path) { opened += 1 }
        viewModel.open()
        #expect(viewModel.isConfirmingCreate == true)
        #expect(opened == 0)

        viewModel.confirmCreate()
        #expect(viewModel.isConfirmingCreate == false)
        #expect(opened == 1)
        #expect(FileManager.default.fileExists(atPath: path))
        // Seeded with documented examples of every recognized key.
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        #expect(contents.contains("tab-close-default"))
    }

    @Test
    func cancelDismissesWithoutSeedingOrOpening() {
        let path = tempConfigPath()
        defer { cleanup(path) }

        var opened = 0
        let viewModel = ConfigSettingsViewModel(configPath: path) { opened += 1 }
        viewModel.open()
        viewModel.cancel()

        #expect(viewModel.isConfirmingCreate == false)
        #expect(opened == 0)
        #expect(FileManager.default.fileExists(atPath: path) == false)
    }
}
