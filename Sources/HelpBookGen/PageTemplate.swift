// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The HTML shell every help page shares, and the stylesheet they link.
///
/// `AppleTitle` is the contract that matters. Help Viewer takes a page's
/// title in search results from that meta tag, not from `<title>`, and a
/// page missing it is indexed under its filename. `AppleIcon` and the
/// robots tag are omitted deliberately: neither affects search, and an
/// icon path that doesn't resolve is one more thing to keep true.
enum PageTemplate {
    /// Deliberately small. Help Viewer supplies its own window chrome and
    /// respects the system appearance, so this sets readable measure and
    /// leaves color to `prefers-color-scheme` rather than fighting it.
    static let styleSheet = """
        :root { color-scheme: light dark; }
        body {
            font: -apple-system-body, system-ui, sans-serif;
            line-height: 1.5;
            margin: 0 auto;
            max-width: 42rem;
            padding: 1.5rem 1.25rem 3rem;
        }
        h1 { font-size: 1.6rem; }
        h2 { font-size: 1.25rem; margin-top: 2rem; }
        h3 { font-size: 1.05rem; }
        code {
            font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
            font-size: 0.9em;
        }
        pre {
            background: color-mix(in srgb, currentColor 8%, transparent);
            border-radius: 6px;
            overflow-x: auto;
            padding: 0.75rem 0.9rem;
        }
        pre code { font-size: 0.85em; }
        table { border-collapse: collapse; display: block; overflow-x: auto; width: 100%; }
        th, td {
            border: 1px solid color-mix(in srgb, currentColor 20%, transparent);
            padding: 0.35rem 0.6rem;
            text-align: left;
            vertical-align: top;
        }
        blockquote {
            border-left: 3px solid color-mix(in srgb, currentColor 25%, transparent);
            margin-left: 0;
            padding-left: 0.9rem;
        }

        """

    static func page(title: String, body: String) -> String {
        let escaped = HTMLRenderer.escape(title)
        return """
            <!DOCTYPE html>
            <html lang="en">
            <head>
            <meta charset="utf-8">
            <meta name="AppleTitle" content="\(escaped)">
            <title>\(escaped)</title>
            <link rel="stylesheet" href="style.css">
            </head>
            <body>
            <h1>\(escaped)</h1>
            \(body)</body>
            </html>

            """
    }
}
