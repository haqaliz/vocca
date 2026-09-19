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
import VoccaActions
import XCTest

/// The JSON-RPC framing layer and the transport seam (`protocol-core` Phase 1).
///
/// ## What is being pinned here, and why it is worth a suite of its own
///
/// Everything in this file is about **a peer we did not write**. The card's Q3 decision removed
/// the transport from this slice precisely so that the framing could be built and driven against
/// hostile input without a pipe in the way: every frame below is a string literal, which is the
/// shape an untrusted peer's bytes actually have. A parser that only ever sees frames its own
/// encoder produced has not been tested; it has been agreed with.
///
/// So the assertions divide in two:
///
/// - **The encoder** must produce `jsonrpc: "2.0"`, a method, params and an id, because that is
///   what the wire format is.
/// - **The decoder** must turn *every* malformation into a **typed failure** — not a trap, not a
///   silent success, not a partially-populated value. `XCTAssertEqual` against an expected
///   `.failure(...)` is the assertion, because a decoder that crashed would take the test process
///   with it and a decoder that shrugged would return `.success` on garbage.
///
/// ## Correlation is by id, and `answers(_:)` is where that lives
///
/// A JSON-RPC peer may answer out of order, so a response is matched to its request **by id** and
/// never by arrival position. ``JSONRPCResponse/answers(_:)`` is the pure predicate that decides
/// it, tested here against two live requests and their responses delivered backwards; the session
/// suite drives the same predicate through the scan loop that consumes it.
///
/// ## There is no transport here, on purpose
///
/// ``InMemoryMCPTransport`` makes **zero syscalls**: it appends frames to an array and pops them
/// off another one. That is what lets the whole protocol layer run honestly inside the
/// zero-network interposer (Phase 4). A test double would have proved the same thing about the
/// double; this is the shipped implementation, and `ActionTransportProhibitionTests` is what keeps
/// it the only kind that may live in this module.
final class MCPProtocolTests: XCTestCase {

    // MARK: - Fixtures

    /// A frame exactly as a peer would hand it over: bytes, with no guarantee attached.
    private func frame(_ text: String) -> Data {
        Data(text.utf8)
    }

    /// The decoded JSON object of an encoded request, for asserting the wire shape field by field
    /// rather than against a golden string whose key order is an encoder detail.
    private func fields(of data: Data) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(value as? [String: Any], "an encoded request must be a JSON object")
    }

    // MARK: - The encoder

    /// A request carries the protocol version, the method, the params and the id.
    func testARequestEncodesAsJSONRPCTwoWithMethodParamsAndAnIdentifier() throws {
        let request = JSONRPCRequest(
            id: .number(7),
            method: "tools/call",
            params: ["name": .string("count-entries"), "arguments": .object(["limit": .number(3)])])

        let encoded = try XCTUnwrap(request.encoded(), "a well-formed request must encode")
        let object = try fields(of: encoded)

        XCTAssertEqual(
            object["jsonrpc"] as? String, "2.0",
            "every frame must declare JSON-RPC 2.0 — a peer is entitled to reject one that does not")
        XCTAssertEqual(object["method"] as? String, "tools/call")
        XCTAssertEqual(
            object["id"] as? Int, 7,
            "the id is what correlates the answer; a request without one can never be answered")

        let params = try XCTUnwrap(object["params"] as? [String: Any])
        XCTAssertEqual(params["name"] as? String, "count-entries")
        let arguments = try XCTUnwrap(
            params["arguments"] as? [String: Any],
            "nested argument objects must survive encoding — tools/call is the reason this layer "
                + "carries arbitrary JSON at all")
        XCTAssertEqual(arguments["limit"] as? Int, 3)
    }

    /// A string id encodes as a string. The spec permits both, and a peer that answered a string
    /// id with a number would otherwise look like a match.
    func testAStringIdentifierEncodesAsAString() throws {
        let request = JSONRPCRequest(id: .text("a1"), method: "tools/list", params: [:])
        let object = try fields(of: try XCTUnwrap(request.encoded()))
        XCTAssertEqual(object["id"] as? String, "a1")
        XCTAssertNil(
            object["id"] as? Int,
            "a string id must not encode as a number — the two are different ids")
    }

    // MARK: - The decoder, on well-formed frames

    /// A result frame decodes into a response carrying its id and its result.
    func testAResultFrameDecodesIntoAResponseCarryingItsIdentifierAndResult() throws {
        let decoded = JSONRPCResponse.decode(
            frame(#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18"}}"#))

        let response = try XCTUnwrap(try decoded.get(), "a well-formed result frame must decode")
        XCTAssertEqual(response.id, .number(1))
        XCTAssertNil(response.error)
        XCTAssertEqual(response.result["protocolVersion"], .string("2025-06-18"))
    }

    /// An **error** response is a typed failure at the point of use — never a trap, and never a
    /// success carrying an empty result.
    ///
    /// Both halves are asserted, because they are different mistakes: decoding must *succeed*
    /// (the frame is well-formed JSON-RPC, and the log wants the peer's own code and message),
    /// while `outcome()` — the accessor every caller goes through — must refuse it.
    func testAnErrorResponseMapsToATypedFailureRatherThanASilentSuccess() throws {
        let decoded = JSONRPCResponse.decode(
            frame(
                #"{"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"Method not found"}}"#))

        let response = try XCTUnwrap(try decoded.get(), "an error frame is still a valid frame")
        XCTAssertEqual(response.error, JSONRPCError(code: -32601, message: "Method not found"))
        XCTAssertEqual(
            response.outcome(),
            .failure(.peerReportedError(JSONRPCError(code: -32601, message: "Method not found"))),
            """
            an error response must surface as a typed failure carrying the peer's own code and \
            message. A caller that read `result` and found it empty would proceed as if the \
            method had succeeded and returned nothing, which is the silent success this assertion \
            exists to make impossible.
            """)
    }

    /// The success half of the same accessor, so the failure above is not passing because
    /// `outcome()` refuses everything.
    func testAResultResponseSurfacesItsResultThroughTheSameAccessor() throws {
        let response = try XCTUnwrap(
            try JSONRPCResponse.decode(frame(#"{"jsonrpc":"2.0","id":3,"result":{"ok":true}}"#))
                .get())
        XCTAssertEqual(response.outcome(), .success(["ok": .bool(true)]))
    }

    // MARK: - The decoder, on hostile frames

    /// **Every malformation is a typed failure.** Table-driven, because the claim is about the
    /// whole class of bad input rather than about one example of it.
    ///
    /// A peer can send any bytes at all. None of these may trap, and none may decode: a frame
    /// with no id cannot be correlated to anything, and a frame with neither `result` nor `error`
    /// answers the request with nothing while looking like an answer.
    func testEveryMalformedFrameIsATypedFailureRatherThanACrash() {
        let cases: [(name: String, frame: String, expected: JSONRPCFailure)] = [
            ("empty bytes", "", .frameIsNotJSON),
            ("not JSON at all", "not json {{{", .frameIsNotJSON),
            ("truncated JSON", #"{"jsonrpc":"2.0","id":1"#, .frameIsNotJSON),
            ("a JSON array", #"[{"jsonrpc":"2.0","id":1,"result":{}}]"#, .frameIsNotAnObject),
            ("a bare JSON string", #""hello""#, .frameIsNotAnObject),
            ("no jsonrpc member", #"{"id":1,"result":{}}"#, .protocolVersionMissing),
            (
                "the wrong protocol version", #"{"jsonrpc":"1.0","id":1,"result":{}}"#,
                .protocolVersionMissing
            ),
            (
                "a numeric protocol version", #"{"jsonrpc":2.0,"id":1,"result":{}}"#,
                .protocolVersionMissing
            ),
            ("no id", #"{"jsonrpc":"2.0","result":{}}"#, .identifierMissing),
            ("a null id", #"{"jsonrpc":"2.0","id":null,"result":{}}"#, .identifierMissing),
            (
                "an object id", #"{"jsonrpc":"2.0","id":{"n":1},"result":{}}"#, .identifierMissing
            ),
            (
                "neither result nor error", #"{"jsonrpc":"2.0","id":1}"#,
                .neitherResultNorError
            ),
            (
                "a non-object result", #"{"jsonrpc":"2.0","id":1,"result":"done"}"#,
                .neitherResultNorError
            ),
        ]

        for testCase in cases {
            XCTAssertEqual(
                JSONRPCResponse.decode(frame(testCase.frame)),
                .failure(testCase.expected),
                """
                a frame with \(testCase.name) must decode to \(testCase.expected). Everything a \
                peer sends is hostile input: the only two acceptable answers are a valid response \
                and a named failure, and a crash would take the whole process with it.
                """)
        }
    }

    // MARK: - Correlation

    /// **An out-of-order response is matched to its own request, by id.**
    ///
    /// The peer answers the second request first. Position says nothing here; only the id does,
    /// which is why the predicate is a function of the two values rather than of arrival order.
    func testAnOutOfOrderResponseIsMatchedToItsOwnRequest() throws {
        let first = JSONRPCRequest(id: .number(1), method: "tools/list", params: [:])
        let second = JSONRPCRequest(id: .number(2), method: "tools/call", params: [:])

        let delivered = [
            try XCTUnwrap(try JSONRPCResponse.decode(frame(#"{"jsonrpc":"2.0","id":2,"result":{"who":"second"}}"#)).get()),
            try XCTUnwrap(try JSONRPCResponse.decode(frame(#"{"jsonrpc":"2.0","id":1,"result":{"who":"first"}}"#)).get()),
        ]

        XCTAssertEqual(
            delivered.first(where: { $0.answers(first) })?.result["who"], .string("first"),
            "the first request must be answered by the frame carrying its id, not by the frame "
                + "that arrived first")
        XCTAssertEqual(
            delivered.first(where: { $0.answers(second) })?.result["who"], .string("second"))
        XCTAssertFalse(
            delivered[0].answers(first),
            "a response bearing another request's id must not answer this one — without this the "
                + "correlation is positional, and a reordering peer would be believed")
    }

    /// A string id and a number id that print the same are not the same id.
    func testAnIdentifierOfADifferentKindDoesNotCorrelate() throws {
        let request = JSONRPCRequest(id: .number(1), method: "tools/list", params: [:])
        let response = try XCTUnwrap(
            try JSONRPCResponse.decode(frame(#"{"jsonrpc":"2.0","id":"1","result":{}}"#)).get())
        XCTAssertEqual(response.id, .text("1"))
        XCTAssertFalse(
            response.answers(request),
            "\"1\" and 1 are different ids; treating them as one would let a peer answer a "
                + "request that was never asked")
    }

    // MARK: - JSON values

    /// **A JSON number is not a boolean.** This is not pedantry: `readOnlyHint` is a boolean, and
    /// `JSONSerialization` hands both booleans and numbers back as `NSNumber`, where `as? Bool`
    /// succeeds for `1`. A server that sent `"readOnlyHint": 1` would otherwise be read as having
    /// claimed read-only — a safety decision made from a value that is not a claim at all.
    func testABooleanAndANumberAreDistinctJSONValues() throws {
        let object = try XCTUnwrap(
            JSONValue.decode(frame(#"{"yes":true,"one":1,"zero":0,"no":false}"#)))
        XCTAssertEqual(
            object,
            .object([
                "yes": .bool(true), "one": .number(1), "zero": .number(0), "no": .bool(false),
            ]),
            """
            booleans must decode as booleans and numbers as numbers. Collapsing them is how a \
            numeric `readOnlyHint` becomes a read-only claim, and the annotation layer's whole \
            job is to read a claim only where one was made.
            """)
    }

    /// The value tree survives a round trip, nesting and nulls included — the property the params
    /// of `tools/call` depend on.
    func testAValueTreeSurvivesARoundTrip() throws {
        let value = JSONValue.object([
            "text": .string("hi"),
            "flag": .bool(false),
            "count": .number(2),
            "nothing": .null,
            "list": .array([.string("a"), .number(1), .object(["deep": .bool(true)])]),
        ])
        let encoded = try XCTUnwrap(value.encoded(), "a value tree must encode")
        XCTAssertEqual(JSONValue.decode(encoded), value)
    }

    // MARK: - The in-memory transport

    /// The transport records **every frame it was sent, in order** — which is how a test asserts
    /// what the session actually asked for rather than what it meant to ask for.
    func testTheTransportRecordsEveryFrameItWasSentInOrder() async {
        let transport = InMemoryMCPTransport(replies: [])
        _ = await transport.send(frame("one"))
        _ = await transport.send(frame("two"))

        let sent = await transport.sentFrames
        XCTAssertEqual(
            sent.map { String(decoding: $0, as: UTF8.self) }, ["one", "two"],
            "the recorded frames are the audit of what was asked; order is part of the record")
    }

    /// Replies are delivered in script order, and the script is exhausted rather than repeated.
    func testRepliesAreDeliveredInScriptOrderAndThenExhausted() async {
        let transport = InMemoryMCPTransport(replies: [frame("first"), frame("second")])

        let first = await transport.receive()
        let second = await transport.receive()
        let third = await transport.receive()

        XCTAssertEqual(first, .success(frame("first")))
        XCTAssertEqual(second, .success(frame("second")))
        XCTAssertEqual(
            third, .failure(.noFrameAvailable),
            """
            an exhausted script must fail rather than replay the last frame. A transport that \
            repeated itself would let a session that asked twice be answered once and never \
            notice.
            """)
    }

    /// A peer that is not there fails **both** directions, and says so as a typed value.
    func testAnUnavailablePeerFailsBothSendAndReceive() async {
        let transport = InMemoryMCPTransport(replies: [frame("unreachable")], isAvailable: false)

        let sent = await transport.send(frame("anything"))
        let received = await transport.receive()

        XCTAssertEqual(sent, .peerUnavailable)
        XCTAssertEqual(
            received, .failure(.peerUnavailable),
            "an unavailable peer must not deliver a scripted frame — the script is what the peer "
                + "would have said, not what it did say")
        let recorded = await transport.sentFrames
        XCTAssertEqual(
            recorded, [],
            "a refused send must not be recorded as a send; the record is of what left, and "
                + "nothing left")
    }
}
