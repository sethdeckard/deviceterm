// SPDX-License-Identifier: GPL-3.0-or-later

/// The CLI's terse parse-failure response.
enum CLIUsage {
    static let text = """
        usage: deviceterm <command> [args...]

        Run `deviceterm help` for the command list, `deviceterm help <command>`
        to read one in full, and `deviceterm agents` for the workflow + triage
        guide.

        """

    static func outcome(message: String?) -> CommandOutcome {
        let diagnostic = message ?? "invalid command"
        let stderr = message.map { "\($0)\n" } ?? ""
        return .failure(
            code: .invalidUsage,
            message: diagnostic,
            stderr: stderr + text
        )
    }
}
