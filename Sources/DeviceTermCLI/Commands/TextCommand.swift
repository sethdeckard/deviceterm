// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser

/// `deviceterm text <string> [--pane <ref>]`.
///
/// The payload is the whole tail, joined with single spaces so a quoted
/// argument carrying spaces survives. `.remaining` collects the
/// non-dashed words while still recognizing this command's own options,
/// so the text can hold anything that does not open with a `-`. One
/// that does takes a `--` ahead of it.
struct TextCommand: FreeTextCommand {
    static let configuration = CommandConfiguration(
        commandName: "text",
        abstract: "Type an ASCII string",
        discussion: HelpText.page(forTopic: "text") ?? ""
    )

    @Option(name: .long, help: "Pane to target.")
    var pane: String?

    @OptionGroup var jsonFlag: JSONFlag

    @Argument(
        parsing: .remaining,
        help: """
        The string to type. A word beginning with - is read as a flag. \
        Put -- before the text to type one literally.
        """
    )
    var words: [String] = []

    var cliCommand: CLICommand {
        guard !words.isEmpty else {
            return .usage(message: "usage: deviceterm text <string> [--pane <ref>]")
        }
        return .text(pane: pane, text: words.joined(separator: " "))
    }
}
