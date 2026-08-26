// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Foundation
import ServiceManagement
import Testing

/// Which `unregister()` failure the repair is allowed to ignore.
///
/// Tolerating one specific failure is the point: a job booted out from under a
/// BTM record that still reads enabled is a state the repair recovers from.
/// Other unregister failures propagate so the caller cannot report a repair
/// after teardown failed.
///
/// `repair()` itself needs a real `SMAppService`, so it is not covered here;
/// this pins the classification it applies.
@MainActor
struct DaemonRegistrationErrorTests {
    private static let domain = "SMAppServiceErrorDomain"

    @Test
    func toleratesJobNotFoundFromTheServiceManagementDomain() {
        let error = NSError(domain: Self.domain, code: kSMErrorJobNotFound)
        #expect(DaemonRegistration.isJobNotFound(error))
    }

    /// The failures that leave a stale registration behind. Ignoring any of
    /// them would produce a false claim that the repair rebuilt the job.
    @Test("propagates every other ServiceManagement failure", arguments: [
        kSMErrorAuthorizationFailure,
        kSMErrorServiceUnavailable,
        kSMErrorInternalFailure,
        kSMErrorInvalidSignature
    ])
    func rejectsOtherServiceManagementCodes(code: Int) {
        let error = NSError(domain: Self.domain, code: code)
        #expect(!DaemonRegistration.isJobNotFound(error))
    }

    /// The code alone doesn't qualify. An unrelated error carrying the same
    /// number propagates, which is the safe direction: an accurate error the
    /// user can retry, rather than a repair claimed but not performed.
    @Test("requires the domain, not just the code", arguments: [
        NSCocoaErrorDomain,
        NSOSStatusErrorDomain,
        NSPOSIXErrorDomain
    ])
    func rejectsMatchingCodeFromAnotherDomain(domain: String) {
        let error = NSError(domain: domain, code: kSMErrorJobNotFound)
        #expect(!DaemonRegistration.isJobNotFound(error))
    }
}
