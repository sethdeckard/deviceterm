// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import DeviceTermUITest

@Suite("doctor: grant reporting + remediation")
struct DoctorTests {
    /// `doctor` must report the *resident's* identity and grants, since
    /// those (not the short-lived client's) are what capture depends on.
    /// The grant booleans are environment-dependent, so this asserts the
    /// shape and the ok/error invariant rather than specific values.
    @Test
    func doctorReportsResidentIdentityAndGrants() throws {
        let path = "/tmp/dt-uitest-\(UUID().uuidString.prefix(8)).sock"
        unlink(path)
        defer { unlink(path) }

        let server = ResidentServer(socketPath: path)
        try server.start()

        let reply = try UITestClient.send(
            UITestRequest(method: .doctor),
            socketPath: path,
            timeout: 2
        )
        let object = try #require(
            try JSONSerialization.jsonObject(with: reply.json) as? [String: Any]
        )

        #expect(object["resident"] as? Bool == true)
        #expect(object["pid"] as? Int == Int(ProcessInfo.processInfo.processIdentifier))
        #expect(object["bundlePath"] is String)
        #expect(object["bundleId"] is String)

        let screenRecording = try #require(object["screenRecording"] as? Bool)
        let accessibility = try #require(object["accessibility"] as? Bool)

        // `ok` summarizes health, and an unhealthy report always names what
        // is missing.
        #expect(reply.ok == (screenRecording && accessibility))
        if !reply.ok {
            let error = try #require(object["error"] as? String)
            #expect(error.contains("missing grants"))
            #expect(error.contains("Screen Recording") == !screenRecording)
            #expect(error.contains("Accessibility") == !accessibility)
        }
    }

    @Test
    func resultBuilderComputesOKRatherThanAssumingIt() throws {
        let data = UITestReply.result(ok: false, ["accessibility": true])
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["ok"] as? Bool == false)
        #expect(object["accessibility"] as? Bool == true)
    }

    /// The remediation must name the *resident's* bundle (granting the
    /// terminal or deviceterm itself is exactly what this design avoids)
    /// and list only the permissions that are actually missing.
    @Test
    func remediationNamesTheResidentBundleAndOnlyMissingGrants() throws {
        let json = try JSONSerialization.data(withJSONObject: [
            "ok": false,
            "bundlePath": "/tmp/DeviceTermUITestHarness.app",
            "screenRecording": false,
            "accessibility": true
        ])
        let text = UITestMain.remediation(forDoctor: json)

        #expect(text.contains("/tmp/DeviceTermUITestHarness.app"))
        #expect(text.contains("Screen Recording"))
        #expect(!text.contains("• Accessibility"))
        #expect(text.contains("not to deviceterm, and not to your terminal"))
    }

    @Test
    func remediationDegradesGracefullyOnAMalformedReply() {
        let text = UITestMain.remediation(forDoctor: Data("not json".utf8))
        #expect(text.contains("the resident harness"))
    }
}
