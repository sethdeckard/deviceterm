// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import Foundation
import Testing

// Helper: encode a Swift dict to JSON bytes for body construction.
private func jsonBytes(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

// Helper: decode JSON bytes back to a Swift dict for body assertions.
private func jsonDict(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

// MARK: - Roundtrip happy paths

@Test
func roundtripsRequestWithEmptyBody() throws {
    let original = RPCEnvelope(
        id: 1,
        type: .request,
        method: "daemon.ping",
        body: .empty
    )
    let bytes = try original.encode()
    let decoded = try RPCEnvelope.decode(bytes)
    #expect(decoded == original)
}

@Test
func roundtripsRequestWithParams() throws {
    let params = try jsonBytes(["udid": "AB12-…", "mode": "detach"])
    let original = RPCEnvelope(
        id: 42,
        type: .request,
        method: "session.close",
        body: .params(params)
    )
    let bytes = try original.encode()
    let decoded = try RPCEnvelope.decode(bytes)
    #expect(decoded.id == 42)
    #expect(decoded.type == .request)
    #expect(decoded.method == "session.close")
    // Compare body via re-parse, since encoding round-trips can re-order
    // keys, so the byte equality on `.params(Data)` isn't a stable
    // assertion.
    guard case let .params(decodedParams) = decoded.body else {
        Issue.record("expected .params body, got \(decoded.body)")
        return
    }
    let decodedDict = try jsonDict(decodedParams)
    #expect((decodedDict["udid"] as? String) == "AB12-…")
    #expect((decodedDict["mode"] as? String) == "detach")
}

@Test
func roundtripsResponseWithResult() throws {
    let result = try jsonBytes(["version": "1.0.0", "pid": 9_876])
    let original = RPCEnvelope(
        id: 7,
        type: .response,
        method: nil,
        body: .result(result)
    )
    let bytes = try original.encode()
    let decoded = try RPCEnvelope.decode(bytes)
    #expect(decoded.id == 7)
    #expect(decoded.type == .response)
    #expect(decoded.method == nil)
    guard case let .result(decodedResult) = decoded.body else {
        Issue.record("expected .result body, got \(decoded.body)")
        return
    }
    let dict = try jsonDict(decodedResult)
    #expect((dict["version"] as? String) == "1.0.0")
    #expect((dict["pid"] as? NSNumber)?.intValue == 9_876)
}

@Test
func roundtripsResponseWithError() throws {
    let original = RPCEnvelope(
        id: 99,
        type: .response,
        method: nil,
        body: .error(RPCError(code: -32_601, message: "Method not found"))
    )
    let bytes = try original.encode()
    let decoded = try RPCEnvelope.decode(bytes)
    #expect(decoded == original)
}

@Test
func roundtripsEventWithParams() throws {
    let params = try jsonBytes(["udid": "AB12", "deviceName": "iPhone 17"])
    let original = RPCEnvelope(
        id: 0,
        // shim events typically use a stable id like 0
        type: .event,
        method: "shim.event",
        body: .params(params)
    )
    let bytes = try original.encode()
    let decoded = try RPCEnvelope.decode(bytes)
    #expect(decoded.id == 0)
    #expect(decoded.type == .event)
    #expect(decoded.method == "shim.event")
}

// MARK: - Encoding shape

@Test
func encodingOmitsOptionalKeysWhenAbsent() throws {
    let envelope = RPCEnvelope(
        id: 1,
        type: .response,
        method: nil,
        body: .empty
    )
    let bytes = try envelope.encode()
    let dict = try jsonDict(bytes)
    #expect(dict["method"] == nil)
    #expect(dict["params"] == nil)
    #expect(dict["result"] == nil)
    #expect(dict["error"] == nil)
    // But id + type are always present.
    #expect((dict["id"] as? NSNumber)?.uint32Value == 1)
    #expect((dict["type"] as? String) == "res")
}

@Test
func encodingProducesStableKeyOrder() throws {
    // sortedKeys ensures the same envelope encodes to identical bytes
    // across runs, which is useful for golden tests and traffic dumps.
    let envelope = RPCEnvelope(
        id: 3,
        type: .request,
        method: "tabs.list",
        body: .empty
    )
    let first = try envelope.encode()
    let second = try envelope.encode()
    #expect(first == second)
}

@Test
func errorEncodingUsesMsgKeyOnWire() throws {
    // The wire-format key is `msg`, not `message`. The Swift API
    // exposes `.message` for ergonomics; the wire keeps `msg`, so a
    // rename on either side is a wire break.
    let envelope = RPCEnvelope(
        id: 1,
        type: .response,
        method: nil,
        body: .error(RPCError(code: 42, message: "boom"))
    )
    let bytes = try envelope.encode()
    let dict = try jsonDict(bytes)
    let errorDict = try #require(dict["error"] as? [String: Any])
    #expect((errorDict["code"] as? NSNumber)?.intValue == 42)
    #expect((errorDict["msg"] as? String) == "boom")
    #expect(errorDict["message"] == nil)
}

// MARK: - Decoding failures

@Test
func decodeRejectsNonObjectJSON() {
    let data = Data("[1,2,3]".utf8)
    #expect(throws: RPCEnvelopeError.notAnObject) {
        _ = try RPCEnvelope.decode(data)
    }
}

@Test
func decodeTreatsMissingIdAsNotification() throws {
    // A request with no `id` is a one-way notification, so it decodes with a
    // nil id rather than throwing.
    let data = Data(#"{"type":"req","method":"pane.surfaceRelease"}"#.utf8)
    let decoded = try RPCEnvelope.decode(data)
    #expect(decoded.id == nil)
    #expect(decoded.type == .request)
    #expect(decoded.method == "pane.surfaceRelease")
}

@Test
func encodeOmitsIdOnNotification() throws {
    let envelope = RPCEnvelope(
        id: nil,
        type: .request,
        method: "pane.surfaceRelease",
        body: .empty
    )
    let bytes = try envelope.encode()
    let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
    #expect(object?["id"] == nil)
    // Round-trips back to a nil id.
    #expect(try RPCEnvelope.decode(bytes).id == nil)
}

@Test
func decodeRejectsNonNumericId() {
    // Present but not a number is malformed, not a notification.
    let data = Data(#"{"id":"nope","type":"req"}"#.utf8)
    #expect(throws: RPCEnvelopeError.invalidId) {
        _ = try RPCEnvelope.decode(data)
    }
}

@Test
func decodeRejectsNegativeId() {
    let data = Data(#"{"id":-1,"type":"req"}"#.utf8)
    #expect(throws: RPCEnvelopeError.invalidId) {
        _ = try RPCEnvelope.decode(data)
    }
}

@Test
func decodeRejectsFractionalId() {
    let data = Data(#"{"id":3.14,"type":"req"}"#.utf8)
    #expect(throws: RPCEnvelopeError.invalidId) {
        _ = try RPCEnvelope.decode(data)
    }
}

@Test
func decodeRejectsFractionalIdThatRoundsToInteger() {
    // `4294967295.00000001` is past Double's precision at that
    // magnitude (~5e-7 ULP near 2^32), so `doubleValue` rounds it to
    // exactly 4294967295.0, which the *previous* fractional check
    // (using doubleValue's integral test) would have silently let
    // through as UInt32.max. The objCType-based gate rejects it
    // correctly: the JSON parser sees the decimal point and stores
    // the value as a Double regardless of how the rounded number
    // looks.
    let data = Data(#"{"id":4294967295.00000001,"type":"req"}"#.utf8)
    #expect(throws: RPCEnvelopeError.invalidId) {
        _ = try RPCEnvelope.decode(data)
    }
}

@Test
func decodeRejectsIntegerWrittenWithDecimalPoint() {
    // `123.0` is mathematically integer but its on-the-wire syntax
    // is the JSON float form. RPC ids must be literal integers.
    let data = Data(#"{"id":123.0,"type":"req"}"#.utf8)
    #expect(throws: RPCEnvelopeError.invalidId) {
        _ = try RPCEnvelope.decode(data)
    }
}

@Test
func decodeRejectsExponentNotation() {
    // `1e3` = 1000 in JSON, parsed as Double. Reject for the same reason
    // as 123.0: literal-integer-on-wire requirement.
    let data = Data(#"{"id":1e3,"type":"req"}"#.utf8)
    #expect(throws: RPCEnvelopeError.invalidId) {
        _ = try RPCEnvelope.decode(data)
    }
}

@Test
func decodeRejectsBooleanId() {
    // `true` and `false` are NSNumbers too, and their `uint32Value` is
    // 1/0, which would otherwise silently work as a valid id.
    let trueData = Data(#"{"id":true,"type":"req"}"#.utf8)
    #expect(throws: RPCEnvelopeError.invalidId) {
        _ = try RPCEnvelope.decode(trueData)
    }
    let falseData = Data(#"{"id":false,"type":"req"}"#.utf8)
    #expect(throws: RPCEnvelopeError.invalidId) {
        _ = try RPCEnvelope.decode(falseData)
    }
}

@Test
func decodeRejectsOutOfRangeId() {
    // UInt32.max + 1, where NSNumber.uint32Value would silently truncate
    // to 0, which is otherwise a valid id.
    let data = Data(#"{"id":4294967296,"type":"req"}"#.utf8)
    #expect(throws: RPCEnvelopeError.invalidId) {
        _ = try RPCEnvelope.decode(data)
    }
}

@Test
func decodeAcceptsBoundaryIds() throws {
    let zero = try RPCEnvelope.decode(Data(#"{"id":0,"type":"req"}"#.utf8))
    #expect(zero.id == 0)
    let max = try RPCEnvelope.decode(Data(#"{"id":4294967295,"type":"req"}"#.utf8))
    #expect(max.id == UInt32.max)
}

@Test
func decodeRejectsMissingType() {
    let data = Data(#"{"id":1,"method":"daemon.ping"}"#.utf8)
    #expect(throws: RPCEnvelopeError.missingType) {
        _ = try RPCEnvelope.decode(data)
    }
}

@Test
func decodeRejectsUnknownType() {
    let data = Data(#"{"id":1,"type":"nope"}"#.utf8)
    #expect(throws: RPCEnvelopeError.unknownType("nope")) {
        _ = try RPCEnvelope.decode(data)
    }
}

@Test
func decodeRejectsMalformedError() {
    // `error` present but missing required `code`.
    let data = Data(#"{"id":1,"type":"res","error":{"msg":"oops"}}"#.utf8)
    #expect(throws: RPCEnvelopeError.invalidError) {
        _ = try RPCEnvelope.decode(data)
    }
}

// MARK: - Method-handler decoding integration

@Test
func paramsBodyCanBeDecodedToTypedStruct() throws {
    struct AttachParams: Codable, Equatable {
        let udid: String
        let sessionId: String
    }
    let originalParams = AttachParams(udid: "AB12-…", sessionId: "01234567-…")
    let paramsData = try JSONEncoder().encode(originalParams)
    let envelope = RPCEnvelope(
        id: 1,
        type: .request,
        method: "device.attach",
        body: .params(paramsData)
    )
    let encoded = try envelope.encode()
    let decoded = try RPCEnvelope.decode(encoded)
    guard case let .params(decodedBytes) = decoded.body else {
        Issue.record("expected .params body")
        return
    }
    let typed = try JSONDecoder().decode(AttachParams.self, from: decodedBytes)
    #expect(typed == originalParams)
}
