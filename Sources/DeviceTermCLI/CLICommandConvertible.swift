// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser

/// A parsed command this CLI owns, carrying the `CLICommand` the
/// dispatcher consumes.
///
/// The conformance is also how a help request is recognized.
/// `parseAsRoot` answers `--help` by returning ArgumentParser's own
/// command type rather than by throwing, and that type is not declared
/// `public`, so it cannot be named in a cast. A parse result that does
/// not conform to this protocol is therefore a help request. The cost of
/// that inference is that a leaf which forgets the conformance is served
/// as help instead of running, with nothing in the build to say so,
/// which is what `CommandTree`'s conformance test exists to catch.
protocol CLICommandConvertible: ParsableCommand {
    /// The dispatcher command these parsed arguments denote.
    var cliCommand: CLICommand { get }
}
