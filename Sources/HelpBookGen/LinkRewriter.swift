// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Repoints the guide's links so they still resolve once the document is
/// one page per topic inside a help bundle.
///
/// Four kinds arrive, and each needs a different answer:
///
///   - **In-document anchors** (`#coexist-with-device-hub`) pointed at a
///     heading in the same file. That heading now lives on some other
///     page, so the link becomes `<page>.html` or `<page>.html#<slug>`
///     depending on whether it names the page's own `##` heading or a
///     `###` inside it.
///   - **Sibling documents** (`AUTOMATION.md`, `INTEGRATION.md#version-report`)
///     are not in the book at all. They go to the published copy on the
///     site, whose Astro layout puts `FOO.md` at `/docs/foo/`.
///   - **Other repository files** (`../Tests/Manual/watchos-checklist.md`)
///     are not published anywhere, so they go to the file on GitHub.
///     Leaving them relative would point them at `en.lproj`, where no
///     part of the repository exists.
///   - **Absolute URLs** are already fine and pass through.
///
/// An anchor with no matching heading is left as written. It was already
/// broken in the source, and quietly pointing it somewhere plausible
/// would hide that.
struct LinkRewriter {
    struct Anchor {
        let page: String
        let isPageTitle: Bool
    }

    /// Base for the published documentation, matching `AppLinks.docs`.
    static let docsBase = "https://deviceterm.com/docs"

    /// Base for files that live only in the repository, matching
    /// `AppLinks.gitHub`. Pinned to `main` rather than a commit: a help
    /// book outlives the build that made it, and a permalink to the
    /// commit it was generated from ages worse than the branch tip.
    static let repositoryBase = "https://github.com/sethdeckard/deviceterm/blob/main"

    /// Heading slug to the page that now carries it, plus whether the
    /// slug is that page's own title.
    let anchors: [String: Anchor]

    /// Resolve a link written inside `docs/` to its repository path.
    /// Returns nil when the path climbs past the repository root, which
    /// is a link this tool has no business guessing at.
    static func resolveFromDocs(_ path: String) -> String? {
        var stack = ["docs"]
        for segment in path.split(separator: "/") {
            switch segment {
            case ".":
                continue

            case "..":
                guard !stack.isEmpty else { return nil }
                stack.removeLast()

            default:
                stack.append(String(segment))
            }
        }
        return stack.isEmpty ? nil : stack.joined(separator: "/")
    }

    func rewrite(_ destination: String) -> String {
        if destination.hasPrefix("#") {
            return rewriteAnchor(String(destination.dropFirst()))
        }
        if let rewritten = rewriteSiblingDocument(destination) {
            return rewritten
        }
        if let rewritten = rewriteRepositoryFile(destination) {
            return rewritten
        }
        return destination
    }

    private func rewriteAnchor(_ slug: String) -> String {
        guard let anchor = anchors[slug] else { return "#\(slug)" }
        return anchor.isPageTitle ? anchor.page : "\(anchor.page)#\(slug)"
    }

    /// `INTEGRATION.md#version-report` → `<docs>/integration/#version-report`.
    /// Returns nil when this isn't a relative link to a sibling `.md`.
    private func rewriteSiblingDocument(_ destination: String) -> String? {
        guard !destination.contains("://") else { return nil }
        let parts = destination.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard let path = parts.first, path.hasSuffix(".md") else { return nil }
        let stem = String(path.dropLast(3)).lowercased()
        // Only the bare siblings are published. A path with a directory
        // in it is some other repository file; `rewriteRepositoryFile`
        // takes those.
        guard !stem.contains("/") else { return nil }
        let fragment = parts.count > 1 ? "#\(parts[1])" : ""
        return "\(Self.docsBase)/\(stem)/\(fragment)"
    }

    /// `../Tests/Manual/watchos-checklist.md` → the file on GitHub.
    /// Returns nil when this isn't a relative link to a repository file.
    private func rewriteRepositoryFile(_ destination: String) -> String? {
        guard !destination.contains("://") else { return nil }
        let parts = destination.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard let path = parts.first, path.hasSuffix(".md"), path.contains("/") else { return nil }
        guard let repoPath = Self.resolveFromDocs(String(path)) else { return nil }
        let fragment = parts.count > 1 ? "#\(parts[1])" : ""
        return "\(Self.repositoryBase)/\(repoPath)\(fragment)"
    }
}
