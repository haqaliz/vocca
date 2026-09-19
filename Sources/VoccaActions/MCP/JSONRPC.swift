// Copyright 2026 The Vocca Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation

// The JSON-RPC 2.0 framing MCP is spoken in.
//
// EVERYTHING BELOW THE ENCODER TREATS ITS INPUT AS HOSTILE. A frame arrives as bytes from a
// program we did not write, chosen by a user we cannot interrogate, and the only two acceptable
// outcomes of reading one are a valid value and a *named* failure. So there is no `try!` in this
// file, no force-unwrap, and no subscript into anything that came off the wire — a malformed
// frame must cost the caller a decision, never the process.

/// A JSON value, as a value type.
///
/// `JSONSerialization` answers in `Any`, which is not `Sendable`, not `Equatable`, and — the part
/// that matters here — **loses the difference between a boolean and a number**: both come back as
/// `NSNumber`, and `as? Bool` succeeds for `1`. That is not an abstract concern. `readOnlyHint` is
/// a boolean, and a server sending `"readOnlyHint": 1` must not be read as having claimed
/// read-only, because a safety decision may only be taken from a claim that was actually made.
/// ``from(_:)`` is where the two are separated, once, so no caller has to remember to.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    indirect case array([JSONValue])
    indirect case object([String: JSONValue])

    /// Reads a `JSONSerialization` value, distinguishing booleans from numbers.
    ///
    /// Anything unrecognised becomes ``null`` rather than trapping: the alternative is a `as!` on
    /// a value a peer chose.
    public static func from(_ value: Any) -> JSONValue {
        if value is NSNull { return .null }
        if let number = value as? NSNumber {
            // The one place the boolean/number collapse is undone. `CFBooleanGetTypeID()` is the
            // only reliable discriminator: `NSNumber(value: 1) as? Bool` is `true`.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return .number(number.doubleValue)
        }
        if let text = value as? String { return .string(text) }
        if let elements = value as? [Any] { return .array(elements.map(JSONValue.from)) }
        if let members = value as? [String: Any] {
            return .object(members.mapValues(JSONValue.from))
        }
        return .null
    }

    /// The `JSONSerialization` representation of this value.
    public var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let flag): return NSNumber(value: flag)
        case .number(let value): return NSNumber(value: value)
        case .string(let text): return text
        case .array(let elements): return elements.map(\.foundationValue)
        case .object(let members): return members.mapValues(\.foundationValue)
        }
    }

    /// Reads a whole frame's worth of bytes. `nil` when the bytes are not JSON at all.
    public static func decode(_ data: Data) -> JSONValue? {
        guard
            let value = try? JSONSerialization.jsonObject(
                with: data, options: [.fragmentsAllowed])
        else {
            return nil
        }
        return .from(value)
    }

    /// Writes this value, with sorted keys so the bytes are stable across calls and processes.
    /// `nil` when the value cannot be serialised.
    public func encoded() -> Data? {
        try? JSONSerialization.data(
            withJSONObject: foundationValue, options: [.sortedKeys, .fragmentsAllowed])
    }
}

/// A JSON-RPC request or response identifier.
///
/// The spec permits a number or a string, and the two are **not interchangeable**: `"1"` and `1`
/// are different ids, so a peer answering one may not be read as answering the other. That
/// distinction is what ``JSONRPCResponse/answers(_:)`` rests on, which is why it is a type rather
/// than a `String` everything is coerced into.
public enum JSONRPCID: Sendable, Equatable, Hashable {
    case number(Int)
    case text(String)

    /// Reads an id from a `JSONSerialization` value. `nil` for anything that is not one —
    /// including `null`, which the spec reserves for notifications and which therefore can never
    /// identify a response to a request.
    init?(foundation value: Any?) {
        guard let value else { return nil }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            self = .number(number.intValue)
            return
        }
        if let text = value as? String {
            self = .text(text)
            return
        }
        return nil
    }

    /// The `JSONSerialization` representation — an `Int`, never a `Double`, so a numeric id
    /// encodes as `7` rather than as `7.0` and comes back the same id it went out as.
    var foundationValue: Any {
        switch self {
        case .number(let value): return value
        case .text(let value): return value
        }
    }
}

/// A request frame: the protocol version, a method, its params and an id.
public struct JSONRPCRequest: Sendable, Equatable {

    /// The only protocol version this layer speaks or accepts.
    public static let protocolVersion = "2.0"

    public let id: JSONRPCID
    public let method: String
    public let params: [String: JSONValue]

    public init(id: JSONRPCID, method: String, params: [String: JSONValue] = [:]) {
        self.id = id
        self.method = method
        self.params = params
    }

    /// The frame's bytes.
    ///
    /// `params` is always written, as an empty object where there are none: `{}` is valid for a
    /// method that takes nothing, and a conditional member is one more shape for a peer to
    /// disagree with us about.
    ///
    /// - Returns: `nil` when the value cannot be serialised — structurally unreachable, since
    ///   every member comes from a ``JSONValue``, and returned rather than trapped for the same
    ///   reason nothing else in this file traps.
    public func encoded() -> Data? {
        let object: [String: Any] = [
            "jsonrpc": Self.protocolVersion,
            "id": id.foundationValue,
            "method": method,
            "params": JSONValue.object(params).foundationValue,
        ]
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

/// The error object a peer may answer with — its own code and its own message, carried verbatim.
public struct JSONRPCError: Sendable, Equatable {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}

/// A response frame: an id, and exactly one of a result or an error.
public struct JSONRPCResponse: Sendable, Equatable {

    public let id: JSONRPCID

    /// The result members, empty when the frame carried an error instead.
    public let result: [String: JSONValue]

    /// The peer's error, when it sent one.
    public let error: JSONRPCError?

    init(id: JSONRPCID, result: [String: JSONValue], error: JSONRPCError?) {
        self.id = id
        self.result = result
        self.error = error
    }

    /// Reads a frame. **The one entry point for bytes that came off the wire.**
    ///
    /// Every rejection is named, and the order of the checks is the order in which the frame
    /// stops being interpretable: bytes that are not JSON, JSON that is not an object, an object
    /// that does not declare JSON-RPC 2.0, one that carries no usable id — and only then the
    /// result/error split.
    ///
    /// An `error` member that is not a well-formed error object is **not an error**, so such a
    /// frame answers with neither and is refused as ``JSONRPCFailure/neitherResultNorError``.
    /// Accepting a half-read error would let a peer report a failure this layer could not
    /// describe.
    public static func decode(_ frame: Data) -> Result<JSONRPCResponse, JSONRPCFailure> {
        guard
            let value = try? JSONSerialization.jsonObject(
                with: frame, options: [.fragmentsAllowed])
        else {
            return .failure(.frameIsNotJSON)
        }
        guard let object = value as? [String: Any] else {
            return .failure(.frameIsNotAnObject)
        }
        guard
            let declared = object["jsonrpc"] as? String,
            declared == JSONRPCRequest.protocolVersion
        else {
            return .failure(.protocolVersionMissing)
        }
        guard let id = JSONRPCID(foundation: object["id"]) else {
            return .failure(.identifierMissing)
        }

        if let raw = object["error"] as? [String: Any] {
            guard
                let code = (raw["code"] as? NSNumber).map({ $0.intValue }),
                let message = raw["message"] as? String
            else {
                return .failure(.neitherResultNorError)
            }
            return .success(
                JSONRPCResponse(
                    id: id, result: [:], error: JSONRPCError(code: code, message: message)))
        }

        guard let raw = object["result"] as? [String: Any] else {
            return .failure(.neitherResultNorError)
        }
        return .success(
            JSONRPCResponse(id: id, result: raw.mapValues(JSONValue.from), error: nil))
    }

    /// Whether this frame answers `request` — **by id, never by arrival order.**
    ///
    /// A peer may answer out of order and may interleave frames of its own, so position says
    /// nothing. Reading a response positionally is how a reordering peer gets believed.
    public func answers(_ request: JSONRPCRequest) -> Bool {
        id == request.id
    }

    /// The result, or the peer's error as a typed failure.
    ///
    /// **The accessor every caller goes through.** Reading ``result`` directly on an error frame
    /// would find it empty and proceed as though the method had succeeded and returned nothing —
    /// a silent success on an explicit failure, which is the single easiest way for this layer to
    /// lie to the one above it.
    public func outcome() -> Result<[String: JSONValue], JSONRPCFailure> {
        if let error { return .failure(.peerReportedError(error)) }
        return .success(result)
    }
}

/// What a frame off the wire can be wrong about.
///
/// Named individually rather than collapsed into one "bad frame", because the layer above reacts
/// differently: a peer that reported an error is speaking the protocol correctly and said no,
/// while bytes that are not a frame at all mean the peer is not speaking the protocol and nothing
/// further from it can be read.
public enum JSONRPCFailure: Error, Sendable, Equatable {

    /// The bytes are not JSON.
    case frameIsNotJSON

    /// The bytes are JSON, but not an object — an array, a bare string, a number.
    case frameIsNotAnObject

    /// No `"jsonrpc": "2.0"` member. Absent, misspelled, or a number rather than a string.
    case protocolVersionMissing

    /// No usable id. Absent, `null`, or a value that is neither a number nor a string — in every
    /// case a frame that cannot be matched to any request.
    case identifierMissing

    /// Neither a result object nor a well-formed error object. The frame answers nothing.
    case neitherResultNorError

    /// The peer answered with an error, carried verbatim.
    case peerReportedError(JSONRPCError)
}
