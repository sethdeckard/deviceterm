// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Resolves an XPC peer's audit token to a signature-validation
/// verdict. Injected into `XPCServer`/`XPCConnection` so tests can
/// substitute a stub for the real signature walk.
///
/// `PeerIdentity.validateGUIPeer` walks the peer's signature via
/// `SecCodeCopyGuestWithAttributes` → `SecCodeCopyStaticCode` →
/// `SecCodeCopySigningInformation`: expensive, and impossible to
/// exercise against an in-process test peer (the test runner *is*
/// `PeerIdentity.selfIdentity`). Routing the daemon's one validation
/// call through this typealias lets the shared `PeerVerdictCache`
/// invoke the injected validator on a cache miss; each connection then
/// retains only a stable result.
///
/// **`defaultPeerValidator` is the only production call site of
/// `PeerIdentity.validateGUIPeer`.** Every other consumer of "is this
/// the validated GUI" reads the resolved verdict instead: the stamped
/// `DispatchPeerContext.validatedGUIPeer` bool, or the value handed to
/// the scope check, never re-validating. A source-level guard
/// (`ValidateGUIPeerCallGuardTests`) asserts no other file *calls* it.
public typealias PeerValidator = @Sendable (audit_token_t) -> PeerIdentity.ValidationResult

/// The production validator: calls `PeerIdentity.validateGUIPeer`
/// directly (the real self-mirror signature check). Tests inject a stub
/// returning a canned `.production` / `.rejected` / `.unavailable` result.
public let defaultPeerValidator: PeerValidator = { PeerIdentity.validateGUIPeer(audit: $0) }
