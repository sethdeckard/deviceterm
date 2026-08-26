// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Derive a tab name from the GUI's CWD if it's in a
/// git worktree.
///
/// Pure logic: takes a path, walks up looking for `.git`, returns the
/// branch name (or short SHA on detached HEAD) or nil. No subprocess
/// to /usr/bin/git, which would require git on PATH at GUI launch, and
/// the formats we care about (`.git/HEAD`, `.git` file pointing at
/// `gitdir: <path>/worktrees/<name>`) are simple enough to parse
/// directly.
///
/// Label-only worktree binding: the tab's `name` field defaults to
/// the branch when CWD is in a worktree. That label is the whole
/// integration; nothing else keys off the worktree.
enum WorktreeName {
    /// Bound the walk-up so a pathological `cwd` (very deep tree)
    /// can't spin. Ten levels is more than enough, since a real worktree
    /// is rarely more than three or four levels from the dev's CWD.
    private static let maxWalkUpDepth = 10

    /// Inspect `cwd` for a git worktree / repo and return a name to
    /// use as the tab's default label. Returns nil when no `.git` is
    /// found, when the HEAD file is unreadable, or when the parsed
    /// reference doesn't yield a usable name. Callers should treat
    /// nil as "no auto-name; leave the tab unnamed."
    static func detect(cwd: String) -> String? {
        guard let gitPath = findGitPath(startingFrom: cwd) else {
            return nil
        }
        guard let headPath = headPath(forGitPath: gitPath) else {
            return nil
        }
        return parseHEAD(at: headPath)
    }

    /// Walk up from `cwd` looking for a `.git` entry (file or
    /// directory). Returns the path to the `.git` entry, or nil if
    /// nothing was found within `maxWalkUpDepth` levels.
    private static func findGitPath(startingFrom cwd: String) -> String? {
        var current = URL(fileURLWithPath: cwd)
        for _ in 0..<maxWalkUpDepth {
            let candidate = current.appendingPathComponent(".git").path
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
            let parent = current.deletingLastPathComponent()
            // Reached filesystem root; deletingLastPathComponent on
            // `/` returns `/` and we'd loop forever otherwise.
            if parent.path == current.path { return nil }
            current = parent
        }
        return nil
    }

    /// Resolve a `.git` entry to the path of the HEAD file. A
    /// regular repo has `.git` as a directory; HEAD lives at
    /// `.git/HEAD`. A worktree has `.git` as a file containing
    /// `gitdir: <repo>/.git/worktrees/<name>`; HEAD lives in that
    /// gitdir.
    private static func headPath(forGitPath gitPath: String) -> String? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: gitPath,
            isDirectory: &isDir
        ) else {
            return nil
        }
        if isDir.boolValue {
            return (gitPath as NSString).appendingPathComponent("HEAD")
        }
        // Worktree: `.git` is a file containing `gitdir: <path>`.
        guard let contents = try? String(
            contentsOfFile: gitPath,
            encoding: .utf8
        ) else {
            return nil
        }
        for rawLine in contents.split(
            separator: "\n",
            omittingEmptySubsequences: true
        ) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("gitdir:") {
                let value = line.dropFirst("gitdir:".count)
                    .trimmingCharacters(in: .whitespaces)
                if !value.isEmpty {
                    return (value as NSString).appendingPathComponent("HEAD")
                }
            }
        }
        return nil
    }

    /// Parse a HEAD file. `ref: refs/heads/<name>` → `<name>`.
    /// Detached HEAD (raw 40-char SHA) → 7-char short SHA. Anything
    /// else → nil.
    private static func parseHEAD(at path: String) -> String? {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8)
        else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ref:") {
            let value = trimmed.dropFirst("ref:".count)
                .trimmingCharacters(in: .whitespaces)
            // `refs/heads/feature/foo` → `feature/foo`; `refs/tags/v1` →
            // `v1`. Anything that doesn't look like a ref → nil.
            let parts = value.split(
                separator: "/",
                maxSplits: 2,
                omittingEmptySubsequences: true
                )
            guard parts.count == 3, parts[0] == "refs" else { return nil }
            return String(parts[2])
        }
        // Detached HEAD: a raw 40-char hex SHA. Anything else
        // (empty, partial, garbage) is unparseable and we return nil.
        let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        if trimmed.count == 40,
            trimmed.unicodeScalars.allSatisfy({ hex.contains($0) }) {
            return String(trimmed.prefix(7))
        }
        return nil
    }
}
