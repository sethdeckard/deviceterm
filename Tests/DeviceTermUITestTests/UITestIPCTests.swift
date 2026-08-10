// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import Testing

@testable import DeviceTermUITest

@Suite("deviceterm-uitest framing + reply shaping")
struct UITestProtocolTests {
    @Test
    func requestFramingRoundTrips() throws {
        let request = UITestRequest(method: .captureWindow, params: ["out": "/tmp/a.png"])
        let body = try JSONEncoder().encode(request)
        let framed = RPCFraming.encode(body)
        let decoded = try #require(try RPCFraming.decodeNext(from: framed))
        let back = try JSONDecoder().decode(UITestRequest.self, from: decoded.payload)
        #expect(back == request)
        #expect(decoded.consumed == framed.count)
    }

    @Test
    func okReplyHasSortedKeysAndOKTrue() throws {
        let data = UITestReply.ok(["pid": 42, "resident": true])
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["ok"] as? Bool == true)
        #expect(object["pid"] as? Int == 42)
        // `.sortedKeys` → "ok" precedes "pid" precedes "resident".
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text == #"{"ok":true,"pid":42,"resident":true}"#)
    }

    @Test
    func failureReplyCarriesMessage() throws {
        let data = UITestReply.failure("boom")
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["ok"] as? Bool == false)
        #expect(object["error"] as? String == "boom")
    }
}

@Suite("deviceterm-uitest socket round-trip")
struct UITestIPCTests {
    /// Bind a resident on a short temp socket path, send a ping through
    /// the real client, and assert the framed reply comes back ok. This
    /// exercises the whole IPC path (bind → accept → frame decode →
    /// dispatch → frame encode → client decode) without any GUI.
    @Test
    func pingRoundTripsThroughTheSocket() throws {
        let path = "/tmp/dt-uitest-\(UUID().uuidString.prefix(8)).sock"
        unlink(path)
        defer { unlink(path) }

        let server = ResidentServer(socketPath: path)
        try server.start()

        let reply = try UITestClient.send(
            UITestRequest(method: .ping),
            socketPath: path,
            timeout: 2
        )
        #expect(reply.ok)
        let object = try #require(
            try JSONSerialization.jsonObject(with: reply.json) as? [String: Any]
        )
        #expect(object["resident"] as? Bool == true)
        #expect(object["tool"] as? String == "deviceterm-uitest")
    }

    /// Every stub must answer with a well-formed failure rather than
    /// hanging or dropping the connection.
    ///
    /// Driven off `Responder.unimplementedMethods` on purpose: naming a
    /// method here by hand once meant this "hermetic" test called
    /// ScreenCaptureKit and passed only because deviceterm happened to be
    /// closed. If something in that list becomes real, this fails loudly.
    /// The implemented capture paths are covered by the non-hermetic
    /// harness track, never here.
    @Test
    func everyUnimplementedMethodRepliesWithAWellFormedFailure() throws {
        let path = "/tmp/dt-uitest-\(UUID().uuidString.prefix(8)).sock"
        unlink(path)
        defer { unlink(path) }

        let server = ResidentServer(socketPath: path)
        try server.start()

        let stubs = Responder.unimplementedMethods.sorted { $0.rawValue < $1.rawValue }
        // Every method has a handler, so there is nothing to pin. Kept
        // (rather than deleted) because the mechanism has to exist the moment
        // a new method lands as a stub.
        guard !stubs.isEmpty else { return }

        for method in stubs {
            let reply = try UITestClient.send(
                UITestRequest(method: method),
                socketPath: path,
                timeout: 2
            )
            #expect(reply.ok == false, "\(method.rawValue) unexpectedly succeeded")
            let object = try #require(
                try JSONSerialization.jsonObject(with: reply.json) as? [String: Any]
            )
            let error = try #require(object["error"] as? String)
            #expect(error.contains("not implemented yet"))
            #expect(error.contains(method.rawValue))
        }
    }

    /// Guards the list above against the failure mode that motivated it:
    /// a method with a real handler must never be claimed as a stub.
    @Test
    func implementedMethodsAreNotListedAsStubs() {
        let implemented: Set<UITestMethod> = [
            .ping, .doctor, .captureWindow, .captureStatusItem, .axDump, .driveKey, .driveClick
        ]
        #expect(Responder.unimplementedMethods.isDisjoint(with: implemented))
        // Every case is accounted for, so a newly-added method can't slip in
        // as neither implemented nor declared a stub.
        #expect(implemented.union(Responder.unimplementedMethods) == Set(UITestMethod.allCases))
    }

    /// Garbage in a well-formed frame must still produce a well-formed
    /// reply. Unlike the stub test, this one can never rot.
    @Test
    func aMalformedRequestFrameRepliesWithAWellFormedFailure() throws {
        let path = "/tmp/dt-uitest-\(UUID().uuidString.prefix(8)).sock"
        unlink(path)
        defer { unlink(path) }

        let server = ResidentServer(socketPath: path)
        try server.start()

        let fd = try UDSClientSocket.connect(to: path)
        defer { UDSClientSocket.close(fd) }
        try UDSClientSocket.writeAll(fd: fd, data: RPCFraming.encode(Data("not json".utf8)))

        var buffer = Data()
        let deadline = Date().addingTimeInterval(2)
        var payload: Data?
        while Date() < deadline, payload == nil {
            guard let chunk = try UDSClientSocket.readAvailable(fd: fd) else { break }
            buffer.append(chunk)
            payload = try RPCFraming.decodeNext(from: buffer)?.payload
            if payload == nil { usleep(2_000) }
        }

        let replyData = try #require(payload)
        let object = try #require(
            try JSONSerialization.jsonObject(with: replyData) as? [String: Any]
        )
        #expect(object["ok"] as? Bool == false)
        #expect(object["error"] as? String == "malformed request frame")
    }

    /// A peer that connects and never sends a frame must not stop the
    /// resident from answering everyone else: accepted connections are
    /// serviced off the accept loop, and each carries an I/O deadline.
    /// Without that, this ping would never get a reply.
    @Test
    func aSilentClientDoesNotWedgeTheResident() throws {
        let path = "/tmp/dt-uitest-\(UUID().uuidString.prefix(8)).sock"
        unlink(path)
        defer { unlink(path) }

        let server = ResidentServer(socketPath: path)
        try server.start()

        // Connect, send nothing, and hold the fd open for the whole test.
        let silent = try UDSClientSocket.connect(to: path)
        defer { UDSClientSocket.close(silent) }

        // A well-behaved client must still get an immediate reply. The
        // 2s client deadline is well inside the resident's 5s I/O deadline,
        // so a wedged accept loop fails this test rather than hiding.
        let reply = try UITestClient.send(
            UITestRequest(method: .ping),
            socketPath: path,
            timeout: 2
        )
        #expect(reply.ok)
    }

    @Test
    func clientReportsWhenNoResidentIsRunning() {
        let path = "/tmp/dt-uitest-absent-\(UUID().uuidString.prefix(8)).sock"
        #expect(throws: UITestClientError.notRunning(path: path)) {
            _ = try UITestClient.send(UITestRequest(method: .ping), socketPath: path, timeout: 1)
        }
    }
}
