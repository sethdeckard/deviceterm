// SPDX-License-Identifier: GPL-3.0-or-later
/// A device answered with a protocol shape deviceterm cannot work with.
///
/// The associated values name only where in the contract the mismatch happened.
/// They never carry a raw device payload, which can hold user or device metadata
/// that must not travel into an error value or a log.
package enum WireCompatibilityError: Error, Sendable, Equatable {
    /// A required field was absent from the reply.
    case missingRequiredField(context: String, field: String)
    /// A required field was present but its value was out of range or the wrong
    /// shape.
    case invalidRequiredValue(context: String, field: String)
    /// A frame arrived that the current protocol state does not allow.
    case unexpectedFrame(context: String)
}
