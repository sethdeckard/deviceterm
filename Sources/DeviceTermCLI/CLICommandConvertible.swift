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

extension CLICommandConvertible {
    /// This command's usage line as a refusal message.
    ///
    /// A `.usage` outcome prints unprefixed, so the `usage:` opener has
    /// to be part of the message. Taking it from `configuration.usage`
    /// rather than restating it keeps the refusal and the help page
    /// showing one spelling of the command's shape.
    static var usageRefusal: String {
        let shape = configuration.usage
            ?? "deviceterm \(configuration.commandName ?? "")"
        return "usage: \(shape)"
    }
}
