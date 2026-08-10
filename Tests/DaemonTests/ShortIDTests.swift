// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import Foundation
import Testing

// MARK: - Alphabet

@Test
func alphabetIsCrockfordBase32Lowercase() {
    // Crockford's base32 minus i/l/o/u, the four letters whose
    // shapes / sounds Crockford reserves to avoid ambiguity. The
    // canonical lowercase set should be 32 characters wide.
    let expected: Set<Character> = Set("0123456789abcdefghjkmnpqrstvwxyz")
    #expect(Set(ShortID.alphabet) == expected)
    #expect(ShortID.alphabet.count == 32)
}

@Test
func alphabetExcludesAmbiguousLetters() {
    let excluded: [Character] = ["i", "l", "o", "u"]
    for letter in excluded {
        #expect(!ShortID.alphabet.contains(letter), "alphabet must not include '\(letter)'")
    }
}

// MARK: - generate

@Test
func generateProducesDefaultLengthSixCharacters() {
    let id = ShortID.generate()
    #expect(id.count == 6)
}

@Test
func generateRespectsLengthOverride() {
    #expect(ShortID.generate(length: 8).count == 8)
    #expect(ShortID.generate(length: 4).count == 4)
}

@Test
func generateUsesAlphabetOnly() {
    // Sample enough draws to make a non-alphabet leak extremely
    // likely if one exists.
    let allowed = Set(ShortID.alphabet)
    for _ in 0..<200 {
        let id = ShortID.generate()
        for character in id {
            #expect(allowed.contains(character))
        }
    }
}

@Test
func generateIsRandomEnoughToVaryDraws() {
    // 32^6 ≈ 1B; two consecutive draws colliding is vanishing. If
    // this test ever fails the RNG is broken.
    let first = ShortID.generate()
    let second = ShortID.generate()
    #expect(first != second)
}

@Test
func generateWithInjectedRNGIsDeterministic() {
    // Deterministic RNG: same seed → same sequence. The
    // collision-retry tests rely on this to stage a forced
    // collision against the live set.
    var rngA = SystemSeededRNG(seed: 0x1234_5678)
    var rngB = SystemSeededRNG(seed: 0x1234_5678)
    let idA = ShortID.generate(using: &rngA)
    let idB = ShortID.generate(using: &rngB)
    #expect(idA == idB)
}

// MARK: - isWellFormed

@Test
func isWellFormedAcceptsValidIds() {
    #expect(ShortID.isWellFormed("abc123"))
    // Reaches into the alphabet's "tail" (no excluded letters):
    // z, y, x, w, v, t are all kept; u is excluded so we use t.
    #expect(ShortID.isWellFormed("zyxwvt", length: 6))
}

@Test
func isWellFormedRejectsLengthMismatch() {
    #expect(!ShortID.isWellFormed("abc12"))
    #expect(!ShortID.isWellFormed("abc1234"))
}

@Test
func isWellFormedRejectsAmbiguousLetters() {
    // The excluded letters never appear in a real short_id, so a
    // `--tab <ref>` containing one definitively isn't a short_id and
    // the resolver should treat it as a name / UUID-prefix candidate
    // instead.
    #expect(!ShortID.isWellFormed("abciln"))  // i + l + n is fine but i/l not in alphabet
    #expect(!ShortID.isWellFormed("oluabc"))
}

@Test
func isWellFormedRejectsUppercase() {
    // Daemon emits lowercased Crockford; uppercase isn't part of the
    // alphabet.
    #expect(!ShortID.isWellFormed("ABC123"))
}

// MARK: - Test helpers

/// Deterministic RNG for collision / mint-strategy tests. Splitmix64
/// is small enough to live next to the test, large enough to give a
/// uniform distribution across `Int.random(in:)`.
private struct SystemSeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
