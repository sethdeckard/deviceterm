// SPDX-License-Identifier: GPL-3.0-or-later
//
// ShortID: daemon-side generator for the human-typeable 6-char tab /
// pane handle (part of the three-layer identifier model).
//
// Crockford base32, lowercased: digits + a..z minus i/l/o/u. Excluding
// the four visually-or-aurally-ambiguous letters keeps a short_id easy
// to read from a terminal screenshot and easy to dictate over voice
// without needing to spell. 32 chars × 6 places ≈ 1 billion values, so
// per-container collisions stay vanishingly rare even at thousands of
// concurrent sessions or panes; the bounded retry in
// `mintShortID(...)` catches the impossible-in-practice exhaustion
// case instead of spinning forever.
//
// The generator stays a pure namespace (no actor state, no I/O) so
// `SessionManager` and `PaneCoordinator` can both call it from inside
// their respective actor isolation domains without crossing a hop.

import Foundation

public enum ShortID {
    /// Crockford base32 (lowercase) minus the four letters Crockford
    /// reserves for ambiguity: `i`, `l`, `o`, `u`. The remaining 32
    /// characters happen to be exactly what a base32 alphabet needs.
    public static let alphabet: [Character] = Array("0123456789abcdefghjkmnpqrstvwxyz")

    /// Default short_id length: 32^6 ≈ 1.07 × 10^9 values, plenty of
    /// headroom against birthday-paradox collisions for any realistic
    /// per-container population (panes per session, sessions per
    /// daemon, etc.). Length is pinned at 6.
    public static let defaultLength = 6

    /// Maximum number of mint attempts before treating the alphabet as
    /// exhausted. Per-container collision probability at this length
    /// is ~10^-9 even with 100 simultaneous mints; 128 tries is a hard
    /// upper bound to keep a buggy RNG from spinning the actor.
    public static let maxMintAttempts = 128

    /// Generate one short_id using a caller-supplied RNG. Tests inject
    /// a deterministic RNG so the collision-retry path is exercisable.
    public static func generate<R: RandomNumberGenerator>(
        using rng: inout R,
        length: Int = defaultLength
    ) -> String {
        var result = ""
        result.reserveCapacity(length)
        for _ in 0..<length {
            let index = Int.random(in: 0..<alphabet.count, using: &rng)
            result.append(alphabet[index])
        }
        return result
    }

    /// Generate one short_id using the system RNG. The non-test entry
    /// point: every daemon mint goes through here.
    public static func generate(length: Int = defaultLength) -> String {
        var rng = SystemRandomNumberGenerator()
        return generate(using: &rng, length: length)
    }

    /// Whether every character of `candidate` is in the short_id
    /// alphabet at the expected length. Used by tests and by the
    /// `--tab <ref>` resolver to short-circuit obvious non-matches.
    public static func isWellFormed(_ candidate: String, length: Int = defaultLength) -> Bool {
        guard candidate.count == length else { return false }
        let allowed = Set(alphabet)
        return candidate.allSatisfy { allowed.contains($0) }
    }
}
