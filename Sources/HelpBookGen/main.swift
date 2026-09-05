// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// deviceterm-helpbook: build-time converter from the markdown guide to
// the HTML page set of DeviceTerm.help.
//
// Writes pages only. The caller owns the bundle around them: the book's
// Info.plist and the `hiutil` index both live in
// `scripts/make-help-book.sh`, because indexing needs the pages on disk
// first and there is no reason for this process to shell out.
//
//     deviceterm-helpbook <guide.md> <output-dir> <book title>
//
// The conversion itself is `HelpBook`, which returns files as strings so
// it can be tested without a filesystem.

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    FileHandle.standardError.write(
        Data("usage: deviceterm-helpbook <guide.md> <output-dir> <book-title>\n".utf8)
    )
    exit(2)
}

let guidePath = arguments[1]
let outputPath = arguments[2]
let bookTitle = arguments[3]

do {
    let markdown = try String(contentsOfFile: guidePath, encoding: .utf8)
    let book = HelpBook(markdown: markdown, title: bookTitle)

    guard !book.topics.isEmpty else {
        // A guide that yields no topics means the split found no `##`
        // heading, which is a changed document rather than an empty one.
        // Failing here beats shipping a book with one dead landing page.
        FileHandle.standardError.write(
            Data("deviceterm-helpbook: no '##' sections found in \(guidePath)\n".utf8)
        )
        exit(1)
    }

    let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true)
    try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
    for file in book.files {
        try file.contents.write(
            to: outputURL.appendingPathComponent(file.name),
            atomically: true,
            encoding: .utf8
        )
    }
    print("deviceterm-helpbook: wrote \(book.files.count) files for \(book.topics.count) topics")
} catch {
    FileHandle.standardError.write(Data("deviceterm-helpbook: \(error)\n".utf8))
    exit(1)
}
