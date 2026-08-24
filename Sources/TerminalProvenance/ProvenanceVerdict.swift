// SPDX-License-Identifier: GPL-3.0-or-later
//
// ProvenanceVerdict: the three outcomes of the provenance decision.
//
// `.notReady` is kept distinct from `.unauthorized` because only the former
// is retryable: it means the session is live but its terminal anchor hasn't
// been bound yet, which the CLI waits out briefly.

import Foundation

public enum ProvenanceVerdict: Sendable, Equatable {
    case authorized
    /// A non-owner UDS peer on a live session with no terminal anchor yet
    /// (owner and validated-GUI callers match an earlier arm); the CLI
    /// retries this briefly.
    case notReady
    /// No provenance arm matched. A wrong terminal identity, a severed
    /// ancestor chain, or a missing identity all land here; the caller must
    /// not retry.
    case unauthorized
}
