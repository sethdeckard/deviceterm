// SPDX-License-Identifier: GPL-3.0-or-later
//
// WorktreeName.detect against synthetic on-disk layouts.
// Each test materializes the minimal `.git` / `.git/HEAD` shape it
// needs in a temp dir, then asserts the detector's answer. No
// subprocess to git; the detector reads files directly.

@testable import App
import Foundation
import Testing

@MainActor
struct WorktreeNameTests {
    // MARK: - Fixture helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deviceterm-worktree-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        return dir
    }

    private func writeFile(_ contents: String, at url: URL) throws {
        try contents.data(using: .utf8)?.write(to: url)
    }

    /// Build a regular-repo layout: `<root>/.git/HEAD` containing the
    /// supplied ref line.
    private func makeRegularRepo(
        at root: URL,
        head: String
    ) throws {
        let gitDir = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(
            at: gitDir,
            withIntermediateDirectories: true
        )
        try writeFile(head, at: gitDir.appendingPathComponent("HEAD"))
    }

    /// Build a worktree layout under `root`: a `<root>/.git` FILE
    /// pointing at a gitdir we also create with its own HEAD.
    private func makeWorktree(
        at root: URL,
        head: String
    ) throws -> URL {
        let gitDir = root.appendingPathComponent("worktree-gitdir")
        try FileManager.default.createDirectory(
            at: gitDir,
            withIntermediateDirectories: true
        )
        try writeFile(head, at: gitDir.appendingPathComponent("HEAD"))
        let gitFile = root.appendingPathComponent(".git")
        try writeFile("gitdir: \(gitDir.path)\n", at: gitFile)
        return gitDir
    }

    // MARK: - Regular repo

    @Test
    func regularRepoReturnsBranchName() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeRegularRepo(at: root, head: "ref: refs/heads/feature-foo\n")
        #expect(WorktreeName.detect(cwd: root.path) == "feature-foo")
    }

    @Test
    func regularRepoHandlesSlashInBranchName() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeRegularRepo(at: root, head: "ref: refs/heads/feature/auth\n")
        #expect(WorktreeName.detect(cwd: root.path) == "feature/auth")
    }

    @Test
    func regularRepoDetachedHEADReturnsShortSHA() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeRegularRepo(
            at: root,
            head: "0123456789abcdef0123456789abcdef01234567\n"
        )
        #expect(WorktreeName.detect(cwd: root.path) == "0123456")
    }

    @Test
    func regularRepoUnreadableHEADReturnsNil() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        // .git exists as a directory but HEAD is absent.
        let gitDir = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(
            at: gitDir,
            withIntermediateDirectories: true
        )
        #expect(WorktreeName.detect(cwd: root.path) == nil)
    }

    @Test
    func regularRepoGarbageHEADReturnsNil() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeRegularRepo(at: root, head: "not a real HEAD\n")
        #expect(WorktreeName.detect(cwd: root.path) == nil)
    }

    @Test
    func regularRepoHEADWithUnexpectedRefShapeReturnsNil() throws {
        // refs/stash or refs/remotes/... shapes don't map to a useful
        // branch name; the detector returns nil rather than printing
        // an unhelpful `stash` or `origin` label.
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeRegularRepo(at: root, head: "ref: stashlike\n")
        #expect(WorktreeName.detect(cwd: root.path) == nil)
    }

    // MARK: - Worktree

    @Test
    func worktreeFileReturnsBranchNameFromGitdir() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeWorktree(at: root, head: "ref: refs/heads/branch-a\n")
        #expect(WorktreeName.detect(cwd: root.path) == "branch-a")
    }

    @Test
    func worktreeFileWithMissingHEADReturnsNil() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let gitDir = root.appendingPathComponent("orphan-gitdir")
        try FileManager.default.createDirectory(
            at: gitDir,
            withIntermediateDirectories: true
        )
        // gitdir exists but no HEAD inside it.
        try writeFile(
            "gitdir: \(gitDir.path)\n",
            at: root.appendingPathComponent(".git")
        )
        #expect(WorktreeName.detect(cwd: root.path) == nil)
    }

    @Test
    func worktreeFileWithoutGitdirLineReturnsNil() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile(
            "something-else: foo\n",
            at: root.appendingPathComponent(".git")
        )
        #expect(WorktreeName.detect(cwd: root.path) == nil)
    }

    // MARK: - Walk-up

    @Test
    func walksUpAncestorsToFindGitDir() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeRegularRepo(at: root, head: "ref: refs/heads/main\n")
        let nested = root.appendingPathComponent("a/b/c")
        try FileManager.default.createDirectory(
            at: nested,
            withIntermediateDirectories: true
        )
        #expect(WorktreeName.detect(cwd: nested.path) == "main")
    }

    @Test
    func notAGitRepoReturnsNil() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(WorktreeName.detect(cwd: root.path) == nil)
    }
}
