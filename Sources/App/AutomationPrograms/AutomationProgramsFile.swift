// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// A read-only reader for `<config home>/deviceterm/automation-programs`.
///
/// Built on the same substrate as `ConfigFile` and `LocationsFile`: the file
/// is held as an ordered list of raw lines and parsed in file order, so tabs
/// open in the order the user wrote them. When each program *starts* is a
/// separate question: its command waits for that tab's grant, and grants
/// resolve independently of one another.
///
/// **deviceterm never writes this file**, which is the whole difference from
/// `LocationsFile`. There is no append, no save, and no gate serializing
/// read-modify-write, because there is no write to serialize. Editing is the
/// user's, by hand, and a change takes effect at the next launch.
///
/// Absent and unreadable are different states and are kept apart. An absent
/// file is the ordinary case: it yields no entries and no defects, so no tab
/// opens. A file that exists and will not decode is a real failure that would
/// otherwise present as "nothing configured" forever with nothing anywhere
/// saying why, so it yields no entries and one `.unreadableFile` defect.
final class AutomationProgramsFile {
    static let defaultPath = XDGPaths.deviceTermAutomationPrograms()

    /// Every block the file defines that deviceterm can run, in file order.
    let entries: [AutomationProgramEntry]

    /// Everything the file said that deviceterm could not use, in file order.
    /// Empty for an absent file.
    let defects: [AutomationProgramDefect]

    init(path: String = AutomationProgramsFile.defaultPath) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            entries = []
            defects = FileManager.default.fileExists(atPath: path)
                ? [AutomationProgramDefect(name: nil, line: 0, reason: .unreadableFile)]
                : []
            return
        }
        // Match ConfigFile and LocationsFile: keep the original split and
        // don't synthesize a trailing empty element for the final newline.
        var lines = text.components(separatedBy: "\n")
        if lines.last?.isEmpty == true { lines.removeLast() }
        let parsed = AutomationProgramsFileParser.parse(
            lines: lines,
            relativeTo: (path as NSString).deletingLastPathComponent
        )
        entries = parsed.entries
        defects = parsed.defects
    }
}
