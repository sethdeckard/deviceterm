// SPDX-License-Identifier: GPL-3.0-or-later
//
// RPCEnvelope: the JSON object shape every framed RPC message wears.
//
// On the wire (after the length prefix from `RPCFraming` peels off):
//
//     {
//       "id":     <uint32, monotonic per client>,  // omitted on a notification
//       "type":   "req" | "res" | "evt",
//       "method": "<name>",         // req or evt only
//       "params": { … },            // req or evt; omitted when none
//       "result": { … },            // res only; omitted on error
//       "error":  { "code": N, "msg": "…" }  // res only on failure
//     }
//
// The envelope is parsed at the routing layer (server-side dispatch
// by `method`, client-side correlation by `id`). The body (`params`,
// `result`, or `error`) is opaque to this layer; method handlers
// decode their own typed structs from the body bytes via `JSONDecoder`.
//
// `id` is optional: a request with no `id` is a **one-way
// notification** the dispatcher runs fire-and-forget, sending no
// response (there is no correlation key to reply on). The surface-
// lease methods, `pane.surfaceRelease` (the watermark ack) and
// `pane.surfaceDrain` (subscription teardown), ride this shape.
// Responses and events always carry the `id` of the request they answer.
//
// Why `Data` and not a typed `params: Codable` generic: the server
// has to peek at `method` before it knows which params type to
// decode, which doesn't fit Codable's static-types model cleanly.
// Keeping the body as raw JSON bytes lets each handler decode its
// own typed `Params` struct without the envelope owning the type
// parameter.

import Foundation

public struct RPCError: Codable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case code
        case message = "msg"
    }

    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}

public struct RPCEnvelope: Sendable, Equatable {
    public enum MessageType: String, Sendable, Equatable {
        case request  = "req"
        case response = "res"
        case event    = "evt"
    }

    /// What follows the routing keys (`id`/`type`/`method`).
    /// Mutually exclusive: an envelope carries exactly one of these.
    public enum Body: Sendable, Equatable {
        /// No body. Used by a request carrying no params (`daemon.ping`,
        /// `daemon.shutdown`; both still return a `result` body), or a
        /// one-way notification with nothing to send.
        case empty
        /// Raw JSON object bytes for a request/event's `params`.
        case params(Data)
        /// Raw JSON object bytes for a response's `result`.
        case result(Data)
        /// Structured failure on a response.
        case error(RPCError)
    }

    /// nil is how a one-way notification (a fire-and-forget request with
    /// no reply) is expressed. By convention a request expecting a reply
    /// and every response/event carry the correlated id; that contract is
    /// upheld by the senders, not structurally enforced by this type.
    public let id: UInt32?
    public let type: MessageType
    public let method: String?
    public let body: Body

    public init(id: UInt32?, type: MessageType, method: String?, body: Body) {
        self.id = id
        self.type = type
        self.method = method
        self.body = body
    }
}

public enum RPCEnvelopeError: Error, Equatable, Sendable {
    case notAnObject
    case invalidId  // present but not a non-negative integer fitting in UInt32
    case missingType
    case unknownType(String)
    case invalidError
    case bodyEncodeFailed
}

public extension RPCEnvelope {
    /// Decode one envelope from raw JSON bytes.
    ///
    /// Uses `JSONSerialization` rather than `Codable` because the body
    /// (`params`/`result`) is a sub-JSON object whose typed shape isn't
    /// known until after we read `method`. Pulling apart with
    /// `JSONSerialization` and re-serializing the body lets us keep
    /// the body as opaque `Data` for downstream handlers to decode.
    static func decode(_ data: Data) throws -> RPCEnvelope {
        let obj = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = obj as? [String: Any] else {
            throw RPCEnvelopeError.notAnObject
        }

        // id: optional. Absent ⇒ a one-way notification the dispatcher
        // runs fire-and-forget (no response). Present ⇒ must be a
        // non-negative integer in UInt32's range. The NSNumber API
        // silently lossy-converts on every failure mode here (negatives
        // wrap, fractionals truncate, booleans become 0/1, overflows
        // wrap), so we validate explicitly. Out-of-range ids would
        // otherwise route response/event frames under the wrong
        // correlation key.
        let id: UInt32?
        if let idAny = dict["id"] {
            guard let idNumber = idAny as? NSNumber else {
                throw RPCEnvelopeError.invalidId
            }
            // 1. Reject booleans first, since NSNumber wraps Bool too, and
            //    `true`/`false` carry objCType "c" (signed char) which
            //    would otherwise pass the integer-storage gate below.
            if CFGetTypeID(idNumber) == CFBooleanGetTypeID() {
                throw RPCEnvelopeError.invalidId
            }
            // 2. Require *integer-backed* NSNumber storage.
            //    JSONSerialization parses JSON `123` as integer-typed
            //    NSNumber but JSON `123.0`, `4294967295.00000001`, or
            //    `1e3` as Double-typed regardless of whether the value
            //    happens to land on a whole number after Double's lossy
            //    rounding. RPC ids must be literal JSON integers on the
            //    wire; reject anything that came through with floating-
            //    point storage. `objCType` strings are `@encode(...)`
            //    codes: c/C/s/S/i/I/l/L/q/Q for signed/unsigned char/
            //    short/int/long/long-long. Doubles are "d", floats "f",
            //    NSDecimalNumber "d".
            let cType = String(cString: idNumber.objCType)
            let integerObjCTypes: Set<String> = ["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q"]
            guard integerObjCTypes.contains(cType) else {
                throw RPCEnvelopeError.invalidId
            }
            // 3. Validate UInt32 range. int64Value is the widest integer
            //    accessor and preserves precision for any integer-backed
            //    NSNumber, so the range check is exact.
            let i64 = idNumber.int64Value
            guard i64 >= 0, i64 <= Int64(UInt32.max) else {
                throw RPCEnvelopeError.invalidId
            }
            id = UInt32(i64)
        } else {
            id = nil
        }

        // type
        guard let typeRaw = dict["type"] as? String else {
            throw RPCEnvelopeError.missingType
        }
        guard let type = MessageType(rawValue: typeRaw) else {
            throw RPCEnvelopeError.unknownType(typeRaw)
        }

        let method = dict["method"] as? String

        // Body: at most one of params/result/error.
        let body: Body
        if let errorAny = dict["error"] {
            guard let errorDict = errorAny as? [String: Any] else {
                throw RPCEnvelopeError.invalidError
            }
            guard let codeNumber = errorDict["code"] as? NSNumber else {
                throw RPCEnvelopeError.invalidError
            }
            let msg = errorDict["msg"] as? String ?? ""
            body = .error(RPCError(code: codeNumber.intValue, message: msg))
        } else if let params = dict["params"] {
            let paramsData = try JSONSerialization.data(withJSONObject: params, options: [])
            body = .params(paramsData)
        } else if let result = dict["result"] {
            let resultData = try JSONSerialization.data(withJSONObject: result, options: [])
            body = .result(resultData)
        } else {
            body = .empty
        }

        return RPCEnvelope(id: id, type: type, method: method, body: body)
    }

    /// Encode the envelope back to JSON object bytes (no length
    /// prefix; pass through `RPCFraming.encode` to wire-frame it).
    func encode() throws -> Data {
        var dict: [String: Any] = [
            "type": type.rawValue
        ]
        // Omit `id` entirely on a notification so the frame is a genuine
        // one-way request on the wire, not `"id": null`.
        if let id {
            dict["id"] = NSNumber(value: id)
        }
        if let method {
            dict["method"] = method
        }
        switch body {
        case .empty:
            break

        case let .params(data):
            dict["params"] = try JSONSerialization.jsonObject(with: data, options: [])

        case let .result(data):
            dict["result"] = try JSONSerialization.jsonObject(with: data, options: [])

        case let .error(error):
            dict["error"] = [
                "code": NSNumber(value: error.code),
                "msg": error.message
            ] as [String: Any]
        }
        guard JSONSerialization.isValidJSONObject(dict) else {
            throw RPCEnvelopeError.bodyEncodeFailed
        }
        // Sort keys so identical envelopes round-trip to the same
        // bytes, useful for golden tests and easier on the eyes when
        // debugging traffic dumps.
        return try JSONSerialization.data(
            withJSONObject: dict,
            options: [.sortedKeys]
        )
    }
}
