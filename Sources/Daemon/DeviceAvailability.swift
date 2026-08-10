// SPDX-License-Identifier: GPL-3.0-or-later
//
// DeviceAvailability: pure decision for whether the daemon can mirror a
// connected physical device, from what a bounded availability probe could
// learn about it.
//
// CoreDevice screen mirroring (the same path Apple's Device Hub uses, which
// is itself iOS-version gated) needs the device to vend
// `com.apple.coredevice.displayservice` and answer `getmediasupportinfo`
// with a non-zero feature set. An older iOS doesn't vend the service at
// all, so its absence is the reliable "can't mirror" signal: capability-
// driven, not a version-number assertion (the exact cutoff is Apple's and
// drifts across betas). A locked or transiently-unreachable device can't be
// probed conclusively, so it is treated as available rather than penalized
// The attach path surfaces the precise error if it really can't mirror.
//
// Pure and total: a probe (catalog + media query) maps its result into a
// `Probe` and this decides; unit-tested without a device.
//
// The gate is enforced at **attach**: the picker lists every
// connected device, and mounting an iOS-too-old one surfaces
// `unsupportedReason`. `decide`/`Probe` hold the
// logic a picker would need to pre-grey unavailable rows by probing
// each device *asynchronously* after the list renders; that probe is
// deliberately kept out of the synchronous `physicalDevice.list` so
// the RPC stays cheap.

enum DeviceAvailability {
    /// What a bounded probe of one connected device learned.
    enum Probe: Sendable, Equatable {
        /// The RSD catalog couldn't be read (device locked / transient).
        /// Inconclusive, so don't block the picker; attach gives the real
        /// error if it matters.
        case catalogUnreachable
        /// The catalog was read but vends no displayservice, so the device's
        /// iOS is too old to mirror.
        case missingDisplayService
        /// `getmediasupportinfo` answered with this feature bitmask.
        case mediaInfo(supportedFeatures: UInt64)
    }

    struct Verdict: Sendable, Equatable {
        let available: Bool
        /// User-facing reason shown in the picker when `available` is false.
        let reason: String?
    }

    /// Reason shown when the device doesn't vend the mirroring service,
    /// almost always an iOS too old for CoreDevice screen mirroring. Pinned
    /// as a constant so the gate's user-facing copy reads in one place.
    static let unsupportedReason = "device doesn't support screen mirroring (needs a newer iOS)"

    static func decide(_ probe: Probe) -> Verdict {
        switch probe {
        case .catalogUnreachable:
            return Verdict(available: true, reason: nil)

        case .missingDisplayService:
            return Verdict(available: false, reason: unsupportedReason)

        case let .mediaInfo(features):
            return features != 0
                ? Verdict(available: true, reason: nil)
                : Verdict(available: false, reason: unsupportedReason)
        }
    }
}
