// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
@testable import Daemon
import Foundation
import Testing

// `CapabilityVerifier`: the non-recoverable credential stored in place of
// the bearer token. Pins the security-relevant properties: the originating
// capability matches, a wrong one doesn't, the verifier is fixed-width, and
// (the load-bearing one) a serialized verifier cannot authenticate as
// though it were the capability.

@Test
func verifierMatchesOriginatingCapability() throws {
    let cap = try Capability.random()
    #expect(CapabilityVerifier(for: cap).matches(cap))
}

@Test
func verifierRejectsWrongCapability() throws {
    let cap = try Capability.random()
    let other = try Capability.random()
    #expect(!CapabilityVerifier(for: cap).matches(other))
}

@Test
func verifierIsExactlyThirtyTwoBytes() throws {
    let verifier = CapabilityVerifier(for: try Capability.random())
    #expect(verifier.bytes.count == CapabilityVerifier.byteCount)
    #expect(CapabilityVerifier.byteCount == 32)
}

@Test
func serializedVerifierDoesNotAuthenticateAsCapability() throws {
    // The core non-replay property: even if an attacker reads the stored
    // verifier and presents its 32 bytes as a bearer capability, the daemon
    // re-hashes that presentation, which cannot equal the stored verifier.
    let cap = try Capability.random()
    let verifier = CapabilityVerifier(for: cap)
    let verifierAsCap = Capability(bytes: verifier.bytes)
    #expect(!verifier.matches(verifierAsCap))
}

@Test
func distinctCapabilitiesProduceDistinctVerifiers() throws {
    let first = CapabilityVerifier(for: try Capability.random())
    let second = CapabilityVerifier(for: try Capability.random())
    #expect(first != second)
}

@Test
func verifierIsDomainSeparatedNotBarePreimageHash() throws {
    // Domain separation, tested directly: compute the *bare* SHA-256 of the
    // capability bytes (no prefix) and assert the verifier differs from it.
    // This fails if the domain prefix is ever dropped: a bare
    // `SHA256(capability)` implementation must not pass.
    let cap = try Capability.random()
    let verifier = CapabilityVerifier(for: cap)
    let bareDigest = Data(SHA256.hash(data: cap.bytes))
    #expect(verifier.bytes != bareDigest)
}
