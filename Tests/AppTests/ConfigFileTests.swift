// SPDX-License-Identifier: GPL-3.0-or-later
//
// ConfigFile round-trip. The load-time guarantee is that a prefs
// write touches only the target key's line and preserves every
// comment, blank, and unknown key verbatim.

@testable import App
import DaemonProtocol
import Foundation
import Testing

private func tempConfigPath() -> String {
    let dir = NSTemporaryDirectory() + "deviceterm-cfgtest-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(
        atPath: dir,
        withIntermediateDirectories: true
    )
    return dir + "/config"
}

@Test
func preservesCommentsAndUnknownKeysWhenSettingExistingKey() throws {
    let path = tempConfigPath()
    let original = """
    # deviceterm config — user comment
    theme = dracula

    # tab behavior
    tab-close-default = detach
    font-size = 13
    """
    try original.write(toFile: path, atomically: true, encoding: .utf8)

    let config = ConfigFile(path: path)
    #expect(config.value(forKey: "tab-close-default") == "detach")
    config.setValue("shutdown", forKey: "tab-close-default")
    try config.save()

    let written = try String(contentsOfFile: path, encoding: .utf8)
    #expect(written.contains("# deviceterm config — user comment"))
    #expect(written.contains("# tab behavior"))
    #expect(written.contains("theme = dracula"))
    #expect(written.contains("font-size = 13"))
    #expect(written.contains("tab-close-default = shutdown"))
    #expect(!written.contains("tab-close-default = detach"))

    let reloaded = ConfigFile(path: path)
    #expect(reloaded.value(forKey: "tab-close-default") == "shutdown")
    #expect(reloaded.value(forKey: "theme") == "dracula")
}

@Test
func appendsMissingKeyWithoutDisturbingOtherLines() throws {
    let path = tempConfigPath()
    let original = """
    # only a comment and one key
    theme = nord
    """
    try original.write(toFile: path, atomically: true, encoding: .utf8)

    let config = ConfigFile(path: path)
    #expect(config.value(forKey: "quit-with-sims-default") == nil)
    config.setValue("keep", forKey: "quit-with-sims-default")
    try config.save()

    let written = try String(contentsOfFile: path, encoding: .utf8)
    #expect(written.contains("# only a comment and one key"))
    #expect(written.contains("theme = nord"))
    #expect(written.contains("quit-with-sims-default = keep"))

    let reloaded = ConfigFile(path: path)
    #expect(reloaded.value(forKey: "quit-with-sims-default") == "keep")
    #expect(reloaded.value(forKey: "theme") == "nord")
}

@Test
func closeDefaultsFixtureRoundTrips() throws {
    // The architecture-checks gate (AGENTS.md) requires
    // a fixture test per new config key. This loads a hand-edited
    // sample via Bundle.module and asserts both tab-close-default
    // and quit-with-sims-default keys read with their fixture
    // values, then proves a write preserves the surrounding
    // comments and unknown keys verbatim.
    let url = try #require(
        Bundle.module.url(
        forResource: "close-defaults",
        withExtension: "config"
    )
        )
    let copy = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("deviceterm-cfg-\(UUID().uuidString).config")
    try FileManager.default.copyItem(atPath: url.path, toPath: copy)

    let config = ConfigFile(path: copy)
    #expect(config.value(forKey: "tab-close-default") == "shutdown")
    #expect(config.value(forKey: "quit-with-sims-default") == "keep")
    #expect(config.value(forKey: "theme") == "nord")

    config.setValue("detach", forKey: "tab-close-default")
    try config.save()
    let written = try String(contentsOfFile: copy, encoding: .utf8)
    #expect(written.contains("# tab close prompt suppressed to shut down"))
    #expect(written.contains("# leave sims alone on quit"))
    #expect(written.contains("theme = nord"))
    #expect(written.contains("font-size = 14"))
    #expect(written.contains("tab-close-default = detach"))
    #expect(written.contains("quit-with-sims-default = keep"))
}

@Test
func advisorySuppressionRoundTrips() throws {
    // The advisory's "Don't show again" writes `suppress` and must
    // read back, leaving any hand-edited neighbors untouched.
    let path = tempConfigPath()
    let original = """
    # user comment
    tab-close-default = detach
    """
    try original.write(toFile: path, atomically: true, encoding: .utf8)

    let config = ConfigFile(path: path)
    #expect(config.value(forKey: "simulator-app-advisory") == nil)
    config.setValue("suppress", forKey: "simulator-app-advisory")
    try config.save()

    let written = try String(contentsOfFile: path, encoding: .utf8)
    #expect(written.contains("# user comment"))
    #expect(written.contains("tab-close-default = detach"))
    #expect(written.contains("simulator-app-advisory = suppress"))

    let reloaded = ConfigFile(path: path)
    #expect(reloaded.value(forKey: "simulator-app-advisory") == "suppress")
}

@Test
func appendingKnownKeyWritesDocComment() throws {
    // Appending a recognized key the app writes must precede it with
    // a doc comment (summary + allowed values + default).
    let path = tempConfigPath()
    let config = ConfigFile(path: path)
    config.setValue("shutdown", forKey: "tab-close-default")
    try config.save()

    let written = try String(contentsOfFile: path, encoding: .utf8)
    let spec = try #require(DeviceTermConfigDefaults.spec(for: "tab-close-default"))
    for line in spec.documentationLines {
        #expect(written.contains(line))
    }
    let docLine = "# Allowed: detach, shutdown. Unset: the Close Tab, Close "
        + "Window, and Close Pane prompts are shown; set detach or shutdown "
        + "to suppress them."
    #expect(written.contains(docLine))
    #expect(written.contains("tab-close-default = shutdown"))
    // The doc comment sits directly above the active line.
    let body = written.components(separatedBy: "\n")
    let keyIndex = try #require(body.firstIndex(of: "tab-close-default = shutdown"))
    #expect(body[keyIndex - 1] == docLine)
}

@Test
func seedingWritesCommentedExamplesForUnsetKeys() throws {
    // After the app sets one key and seeds, every *other* recognized
    // key appears as a commented-out example, never as an active
    // line, so reads of unset keys still fall through to defaults.
    let path = tempConfigPath()
    let config = ConfigFile(path: path)
    config.setValue("suppress", forKey: "simulator-app-advisory")
    config.seedDocumentedExamples()
    try config.save()

    let reloaded = ConfigFile(path: path)
    #expect(reloaded.value(forKey: "simulator-app-advisory") == "suppress")
    // Unset keys are present only as commented examples → read as nil.
    #expect(reloaded.value(forKey: "tab-close-default") == nil)
    #expect(reloaded.value(forKey: "quit-with-sims-default") == nil)

    let written = try String(contentsOfFile: path, encoding: .utf8)
    #expect(written.contains("# tab-close-default = detach"))
    #expect(written.contains("# quit-with-sims-default = keep"))
}

@Test
func seedingIsIdempotent() throws {
    // Seeding twice must not duplicate examples: the second pass sees
    // every key already present (active or commented) and adds nothing.
    let path = tempConfigPath()
    let config = ConfigFile(path: path)
    config.setValue("suppress", forKey: "simulator-app-advisory")
    config.seedDocumentedExamples()
    try config.save()
    let firstPass = try String(contentsOfFile: path, encoding: .utf8)

    let again = ConfigFile(path: path)
    again.seedDocumentedExamples()
    try again.save()
    let secondPass = try String(contentsOfFile: path, encoding: .utf8)

    #expect(firstPass == secondPass)
}

@Test
func seedingSkipsKeysAlreadyHandEditedAsExamples() throws {
    // A user who left a `# key = value` example in place must not get
    // a duplicate when the app seeds.
    let path = tempConfigPath()
    let original = """
    # tab-close-default = shutdown
    """
    try original.write(toFile: path, atomically: true, encoding: .utf8)

    let config = ConfigFile(path: path)
    config.seedDocumentedExamples()
    try config.save()

    let written = try String(contentsOfFile: path, encoding: .utf8)
    let occurrences = written.components(separatedBy: "tab-close-default").count - 1
    #expect(occurrences == 1)
}

@Test
func ignoresCommentedAndMalformedLines() throws {
    let path = tempConfigPath()
    let original = """
    # tab-close-default = shutdown
    not-a-config-line
    tab-close-default = detach
    """
    try original.write(toFile: path, atomically: true, encoding: .utf8)

    let config = ConfigFile(path: path)
    // The commented line must not be read as the value.
    #expect(config.value(forKey: "tab-close-default") == "detach")

    let reloaded = ConfigFile(path: path)
    let written = try String(contentsOfFile: path, encoding: .utf8)
    _ = reloaded
    #expect(written.contains("not-a-config-line"))
}
