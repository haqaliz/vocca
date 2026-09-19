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

/// ``MCPSession`` — `initialize` negotiation, `tools/list` discovery and `tools/call`
/// (`protocol-core` Phase 2).
///
/// ## The two fail-safe defaults this suite exists for
///
/// Both are **acceptances, not implementation taste**, and both are about what happens when the
/// peer says nothing rather than when it says something wrong:
///
/// **(a) A tool with no `readOnlyHint` is treated as NOT read-only.** Missing annotations are the
/// common case in real MCP servers — most tools ship with none at all — so the safe reading of
/// silence has to be the implemented one. `action-safety-spine` recorded, before MCP existed,
/// that a blast radius is the provider's own claim and nothing verifies it, so local policy may
/// only ever *escalate*. An absent hint is not a claim; reading it as one would be a
/// de-escalation performed by omission, which is the cheapest possible way for the whole safety
/// spine to be defeated. Three tests hold this line: the absent hint, the non-boolean hint, and
/// the present-and-true hint that stops the other two from passing because nothing is ever
/// read-only.
///
/// **(b) A server that fails `initialize` leaves the session UNUSABLE.** Not degraded, not
/// retried — unusable. The assertion is deliberately made on the **transport's record** as well
/// as on the returned failure: `tools/list` must not merely return an error, it must never have
/// been *sent*. A session that asked an unnegotiated peer for its tools and then discarded the
/// answer would satisfy a return-value check while having spoken to a peer it had no agreement
/// with.
///
/// ## Everything off the wire is hostile
///
/// The frames below are string literals. A malformed tool list yields **no tools** rather than a
/// partial list of half-parsed ones, because a partial list is the dangerous answer: the tools
/// that survived parsing would be presented as the server's offering, and the ones that did not
/// would be invisible — including, potentially, the annotation that would have made a surviving
/// tool look safe.
final class MCPSessionTests: XCTestCase {

    // MARK: - Fixtures

    private static let clientName = "vocca-test-client"
    private static let clientVersion = "9.9.9"

    private func frame(_ text: String) -> Data {
        Data(text.utf8)
    }

    /// The server's well-formed answer to `initialize`, for request id 1.
    private var initializeReply: Data {
        frame(
            """
            {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"\(MCPSession.protocolVersion)",\
            "capabilities":{"tools":{}},\
            "serverInfo":{"name":"scripted-server","version":"2.1"}}}
            """)
    }

    private func session(replies: [Data], isAvailable: Bool = true) -> (
        MCPSession, InMemoryMCPTransport
    ) {
        let transport = InMemoryMCPTransport(replies: replies, isAvailable: isAvailable)
        let session = MCPSession(
            transport: transport, clientName: Self.clientName, clientVersion: Self.clientVersion)
        return (session, transport)
    }

    /// The method of every frame the session sent, in order — read off the transport's record
    /// rather than off anything the session claims about itself.
    private func methodsAsked(of transport: InMemoryMCPTransport) async -> [String] {
        await transport.sentMethods
    }

    private func decodedParams(of frame: Data) throws -> [String: Any] {
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: frame) as? [String: Any])
        return try XCTUnwrap(object["params"] as? [String: Any], "the frame must carry params")
    }

    // MARK: - initialize

    /// The negotiation sends the protocol version and the client identity, and parses the
    /// server's reply back into an identity of its own.
    func testInitializeSendsTheProtocolVersionAndClientInfoAndParsesTheReply() async throws {
        let (session, transport) = self.session(replies: [initializeReply])

        let result = await session.initialize()

        XCTAssertEqual(
            result,
            .success(
                MCPServerIdentity(
                    name: "scripted-server", version: "2.1",
                    protocolVersion: MCPSession.protocolVersion)),
            "the server's declared identity must survive the frame — it is what a later surface "
                + "would name when asking the user to allow anything at all")
        let negotiation = await session.negotiation
        XCTAssertEqual(negotiation, .negotiated)

        let asked = await methodsAsked(of: transport)
        XCTAssertEqual(asked, ["initialize"])
        let sent = await transport.sentFrames
        let params = try decodedParams(of: try XCTUnwrap(sent.first))
        XCTAssertEqual(params["protocolVersion"] as? String, MCPSession.protocolVersion)
        XCTAssertNotNil(
            params["capabilities"] as? [String: Any],
            "capabilities must be declared, even as an empty object — a peer is entitled to "
                + "branch on what we said we can do")
        let clientInfo = try XCTUnwrap(params["clientInfo"] as? [String: Any])
        XCTAssertEqual(clientInfo["name"] as? String, Self.clientName)
        XCTAssertEqual(clientInfo["version"] as? String, Self.clientVersion)
    }

    /// The shipped client identity is not empty — otherwise the assertion above passes over
    /// injected values while every real negotiation announces nothing.
    func testTheShippedClientIdentityIsNotEmpty() {
        XCTAssertFalse(MCPSession.clientName.isEmpty)
        XCTAssertFalse(MCPSession.clientVersion.isEmpty)
        XCTAssertFalse(MCPSession.protocolVersion.isEmpty)
    }

    // MARK: - Fail-safe default (b): a failed negotiation leaves the session unusable

    /// **A server that fails `initialize` leaves the session unusable**, and `tools/list` is
    /// never sent.
    func testAServerThatFailsInitializeLeavesTheSessionUnusable() async throws {
        let (session, transport) = self.session(replies: [
            frame(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32603,"message":"no"}}"#),
            // A tool list the peer would happily answer with, scripted on purpose: if the
            // session proceeded, it would find a perfectly good answer waiting and look correct.
            frame(#"{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"anything"}]}}"#),
        ])

        let negotiation = await session.initialize()
        XCTAssertEqual(
            negotiation,
            .failure(.frame(.peerReportedError(JSONRPCError(code: -32603, message: "no")))),
            "a refused negotiation must surface the peer's own error rather than a generic one")

        let tools = await session.listTools()
        XCTAssertEqual(
            tools, .failure(.notNegotiated),
            """
            tools/list against an unnegotiated peer must fail. Proceeding would mean discovering \
            tools from a server we never agreed a protocol version with — and the scripted reply \
            above proves the failure is a refusal rather than an absence of anything to read.
            """)
        let asked = await methodsAsked(of: transport)
        XCTAssertEqual(
            asked, ["initialize"],
            """
            the refusal must happen BEFORE the request leaves. A session that asked and then \
            discarded the answer would pass a return-value check while having spoken to a peer \
            it had no agreement with.
            """)
        let state = await session.negotiation
        XCTAssertEqual(state, .refused)
    }

    /// The same, for the other way a negotiation fails: a peer that is not there at all.
    func testAnUnavailablePeerAlsoLeavesTheSessionUnusable() async {
        let (session, transport) = self.session(
            replies: [initializeReply], isAvailable: false)

        let negotiation = await session.initialize()
        XCTAssertEqual(negotiation, .failure(.transport(.peerUnavailable)))

        let call = await session.callTool("anything", arguments: [:])
        XCTAssertEqual(
            call, .failure(.notNegotiated),
            "tools/call is refused for the same reason tools/list is — invoking against a peer "
                + "we never negotiated with is the one thing an unusable session must not do")
        let asked = await methodsAsked(of: transport)
        XCTAssertEqual(asked, [])
    }

    /// Negotiation happens **once**. A refused session is not retried into usefulness by asking
    /// again — which would turn "unusable" into "unusable until the caller loops".
    func testARefusedSessionIsNotRenegotiable() async {
        let (session, transport) = self.session(replies: [
            frame(#"{"jsonrpc":"2.0","id":1,"error":{"code":-1,"message":"refused"}}"#),
            initializeReply,
        ])

        _ = await session.initialize()
        let retry = await session.initialize()

        XCTAssertEqual(retry, .failure(.notNegotiated))
        let asked = await methodsAsked(of: transport)
        XCTAssertEqual(
            asked, ["initialize"],
            "the retry must not reach the peer — the scripted second reply would have negotiated "
                + "successfully, which is exactly the loop this refusal closes")
    }

    /// A peer answering with a protocol version we do not speak refuses the negotiation rather
    /// than proceeding on the peer's terms.
    func testAnUnsupportedProtocolVersionRefusesTheNegotiation() async {
        let (session, _) = self.session(replies: [
            frame(
                #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"1999-01-01","serverInfo":{"name":"old","version":"0"}}}"#
            )
        ])

        let result = await session.initialize()
        XCTAssertEqual(result, .failure(.unsupportedProtocolVersion("1999-01-01")))
        let state = await session.negotiation
        XCTAssertEqual(state, .refused)
    }

    /// A reply that is well-formed JSON-RPC but not a well-formed `initialize` result is a named
    /// failure, not a half-built identity.
    func testAMalformedInitializeResultIsATypedFailure() async {
        let (session, _) = self.session(replies: [
            frame(
                """
                {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"\(MCPSession.protocolVersion)",\
                "serverInfo":{"version":"2.1"}}}
                """)
        ])

        let result = await session.initialize()
        XCTAssertEqual(
            result, .failure(.malformedResult("serverInfo.name")),
            "the failure must name the member that was wrong — an unnamed parse failure against "
                + "an untrusted peer is unactionable")
    }

    // MARK: - tools/list

    /// Discovery parses descriptors, annotations included, and asks for them by the spec's
    /// method name.
    func testListToolsParsesDescriptorsIncludingAnnotations() async throws {
        let (session, transport) = self.session(replies: [
            initializeReply,
            frame(
                """
                {"jsonrpc":"2.0","id":2,"result":{"tools":[\
                {"name":"count-entries","description":"Count the entries.",\
                "annotations":{"readOnlyHint":true}},\
                {"name":"clear-log","description":"Clear the log.",\
                "annotations":{"readOnlyHint":false}}]}}
                """),
        ])

        _ = await session.initialize()
        let tools = await session.listTools()

        XCTAssertEqual(
            tools,
            .success([
                MCPToolDescriptor(
                    name: "count-entries", summary: "Count the entries.",
                    annotations: MCPToolAnnotations(declaredReadOnly: true)),
                MCPToolDescriptor(
                    name: "clear-log", summary: "Clear the log.",
                    annotations: MCPToolAnnotations(declaredReadOnly: false)),
            ]))
        let asked = await methodsAsked(of: transport)
        XCTAssertEqual(asked, ["initialize", "tools/list"])
    }

    // MARK: - Fail-safe default (a): absent means unsafe

    /// **A tool with no `readOnlyHint` is treated as NOT read-only.**
    ///
    /// Asserted at both levels: the descriptor records that no claim was made
    /// (`declaredReadOnly == nil`), and the question a caller actually asks — `isReadOnly` —
    /// answers `false`. Recording the absence and then resolving it the unsafe way is the whole
    /// of the default; a type that could not tell "absent" from "false" would be unable to say
    /// later that the server never claimed anything.
    func testAToolWithNoReadOnlyHintIsNotTreatedAsReadOnly() async throws {
        let (session, _) = self.session(replies: [
            initializeReply,
            frame(
                """
                {"jsonrpc":"2.0","id":2,"result":{"tools":[\
                {"name":"unannotated","description":"Says nothing about itself."},\
                {"name":"empty-annotations","description":"Says nothing, at length.",\
                "annotations":{}}]}}
                """),
        ])

        _ = await session.initialize()
        let listed = await session.listTools()
        let tools = try XCTUnwrap(try listed.get())

        XCTAssertEqual(tools.count, 2)
        for tool in tools {
            XCTAssertNil(
                tool.annotations.declaredReadOnly,
                "\(tool.name) made no read-only claim, and the descriptor must record that no "
                    + "claim was made rather than inventing a false one")
            XCTAssertFalse(
                tool.annotations.isReadOnly,
                """
                \(tool.name) has no readOnlyHint and must NOT be treated as read-only. Absent \
                means unsafe: missing annotations are the common case in real servers, so the \
                safe reading of silence has to be the implemented one. Reading silence as a \
                read-only claim is a de-escalation performed by omission.
                """)
        }
    }

    /// The other half of (a): a hint that is present but is not a boolean is not a claim either.
    ///
    /// `JSONSerialization` will hand `1` back as an `NSNumber` that `as? Bool` accepts, so
    /// without a boolean-typed read a server sending `"readOnlyHint": 1` — or the string
    /// `"true"` — would be believed.
    func testANonBooleanReadOnlyHintIsNotTreatedAsReadOnly() async throws {
        let (session, _) = self.session(replies: [
            initializeReply,
            frame(
                """
                {"jsonrpc":"2.0","id":2,"result":{"tools":[\
                {"name":"numeric","annotations":{"readOnlyHint":1}},\
                {"name":"stringly","annotations":{"readOnlyHint":"true"}},\
                {"name":"null-hint","annotations":{"readOnlyHint":null}}]}}
                """),
        ])

        _ = await session.initialize()
        let listed = await session.listTools()
        let tools = try XCTUnwrap(try listed.get())

        XCTAssertEqual(tools.map(\.name), ["numeric", "stringly", "null-hint"])
        for tool in tools {
            XCTAssertFalse(
                tool.annotations.isReadOnly,
                """
                \(tool.name)'s readOnlyHint is not a boolean, so no read-only claim was made. \
                `1` and `"true"` are not the claim the annotation names, and a safety decision \
                may not be taken from a value that is not one.
                """)
        }
    }

    /// The control that stops the two tests above from passing because nothing is ever read-only.
    func testAPresentReadOnlyHintIsHonoured() async throws {
        let (session, _) = self.session(replies: [
            initializeReply,
            frame(
                #"{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"honest","annotations":{"readOnlyHint":true}}]}}"#
            ),
        ])

        _ = await session.initialize()
        let listed = await session.listTools()
        let tools = try XCTUnwrap(try listed.get())
        XCTAssertEqual(tools.first?.annotations.declaredReadOnly, true)
        XCTAssertTrue(
            tools.first?.annotations.isReadOnly ?? false,
            "a tool that does claim read-only must read as read-only — otherwise the absent-hint "
                + "assertions above are passing for the wrong reason")
    }

    // MARK: - A malformed tool list yields no tools

    /// **A malformed tool list yields no tools, never a partial list of half-parsed ones.**
    ///
    /// Table-driven over the ways the list can be wrong, with the first case the load-bearing
    /// one: a list whose *first* entry is perfectly good and whose second is not. A parser that
    /// collected what it could would hand back one tool and no indication that anything was
    /// missing — and the caller would present a truncated offering as the server's.
    func testAMalformedToolListYieldsNoToolsRatherThanAPartialList() async {
        let lists: [(name: String, result: String)] = [
            (
                "a good entry followed by a nameless one",
                #"{"tools":[{"name":"good","annotations":{"readOnlyHint":true}},{"description":"no name"}]}"#
            ),
            ("an empty tool name", #"{"tools":[{"name":""}]}"#),
            ("a non-string tool name", #"{"tools":[{"name":42}]}"#),
            ("a tool that is not an object", #"{"tools":["count-entries"]}"#),
            ("a tools member that is not an array", #"{"tools":{"name":"count"}}"#),
            ("no tools member at all", #"{"nextCursor":"abc"}"#),
        ]

        for list in lists {
            let (session, _) = self.session(replies: [
                initializeReply,
                frame(#"{"jsonrpc":"2.0","id":2,"result":"# + list.result + #"}"#),
            ])
            _ = await session.initialize()

            let listed = await session.listTools()
            XCTAssertEqual(
                listed, .failure(.malformedToolList),
                """
                \(list.name) must yield NO tools. A partial list is the dangerous answer: the \
                entries that parsed would be presented as the server's whole offering, and \
                whatever did not parse — an annotation among it — would be invisible.
                """)
        }
    }

    /// A server with nothing to offer is not a malformed one. Empty is a legitimate answer, and
    /// conflating it with a parse failure would make the assertion above unfalsifiable.
    func testAnEmptyToolListIsASuccessfulEmptyAnswer() async {
        let (session, _) = self.session(replies: [
            initializeReply,
            frame(#"{"jsonrpc":"2.0","id":2,"result":{"tools":[]}}"#),
        ])
        _ = await session.initialize()
        let listed = await session.listTools()
        XCTAssertEqual(listed, .success([]))
    }

    // MARK: - tools/call

    /// The call sends the name and the arguments, and returns the server's content.
    func testCallToolSendsNameAndArgumentsAndReturnsTheContent() async throws {
        let (session, transport) = self.session(replies: [
            initializeReply,
            frame(
                """
                {"jsonrpc":"2.0","id":2,"result":{"content":[\
                {"type":"text","text":"12 entries"},\
                {"type":"image","data":"ignored"},\
                {"type":"text","text":"done"}],"isError":false}}
                """),
        ])

        _ = await session.initialize()
        let result = await session.callTool(
            "count-entries", arguments: ["limit": .number(3), "verbose": .bool(true)])

        XCTAssertEqual(
            result,
            .success(MCPToolCallResult(textContent: ["12 entries", "done"], isError: false)),
            "the text blocks are returned in order and the block kinds this layer does not "
                + "render are skipped rather than failing the call")
        let asked = await methodsAsked(of: transport)
        XCTAssertEqual(asked, ["initialize", "tools/call"])

        let sent = await transport.sentFrames
        let params = try decodedParams(of: try XCTUnwrap(sent.last))
        XCTAssertEqual(params["name"] as? String, "count-entries")
        let arguments = try XCTUnwrap(
            params["arguments"] as? [String: Any],
            "tools/call takes a name AND an arguments object — a call that dropped the arguments "
                + "would run a different action from the one that was asked for")
        XCTAssertEqual(arguments["limit"] as? Int, 3)
        XCTAssertEqual(arguments["verbose"] as? Bool, true)
    }

    /// A tool that reports its own failure is a successful call carrying `isError` — the
    /// distinction between "the call did not happen" and "the tool ran and said no".
    func testAToolReportedErrorIsCarriedRatherThanCollapsed() async {
        let (session, _) = self.session(replies: [
            initializeReply,
            frame(
                #"{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"nope"}],"isError":true}}"#
            ),
        ])
        _ = await session.initialize()
        let called = await session.callTool("failing", arguments: [:])
        XCTAssertEqual(
            called,
            .success(MCPToolCallResult(textContent: ["nope"], isError: true)),
            "a tool that ran and refused is not a protocol failure, and collapsing the two would "
                + "lose the only signal that the tool itself was reached")
    }

    /// A protocol-level error on `tools/call` is a typed failure carrying the peer's code.
    func testAProtocolErrorOnCallToolIsATypedFailure() async {
        let (session, _) = self.session(replies: [
            initializeReply,
            frame(
                #"{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"Unknown tool"}}"#),
        ])
        _ = await session.initialize()
        let called = await session.callTool("missing", arguments: [:])
        XCTAssertEqual(
            called,
            .failure(.frame(.peerReportedError(JSONRPCError(code: -32602, message: "Unknown tool")))))
    }

    /// A result with no `content` member is a named failure rather than an empty success.
    func testAResultWithoutContentIsATypedFailure() async {
        let (session, _) = self.session(replies: [
            initializeReply,
            frame(#"{"jsonrpc":"2.0","id":2,"result":{"isError":false}}"#),
        ])
        _ = await session.initialize()
        let called = await session.callTool("count-entries", arguments: [:])
        XCTAssertEqual(
            called,
            .failure(.malformedResult("content")),
            "an empty success here would report that a tool ran and returned nothing, which is "
                + "indistinguishable from a tool that ran and returned something we could not read")
    }

    // MARK: - Correlation, through the session

    /// The session skips a frame that answers a different request and keeps looking for its own.
    ///
    /// This is the framing suite's `answers(_:)` predicate driven through the loop that consumes
    /// it: the peer interleaves a response to an id that was never asked for, and the negotiation
    /// still completes.
    func testAFrameAnsweringAnotherRequestIsSkippedUntilTheMatchingOneArrives() async {
        let (session, _) = self.session(replies: [
            frame(#"{"jsonrpc":"2.0","id":99,"result":{"stray":true}}"#),
            initializeReply,
        ])

        let result = await session.initialize()
        XCTAssertEqual(
            result,
            .success(
                MCPServerIdentity(
                    name: "scripted-server", version: "2.1",
                    protocolVersion: MCPSession.protocolVersion)),
            "a response bearing an id we did not ask for must be discarded, not mistaken for "
                + "ours — correlation is by id, never by arrival order")
    }

    /// A peer that answers only with frames for other requests is refused, bounded, rather than
    /// scanned forever.
    func testAPeerThatNeverAnswersTheRequestIsRefusedRatherThanScannedForever() async {
        let strays = (0..<64).map {
            frame(#"{"jsonrpc":"2.0","id":\#($0 + 1000),"result":{}}"#)
        }
        let (session, _) = self.session(replies: strays)

        let result = await session.initialize()
        XCTAssertEqual(
            result, .failure(.unanswered),
            """
            a peer that never answers must be refused after a bounded scan. An unbounded search \
            for a matching id is a hostile peer's cheapest way to hang the process that trusted \
            it.
            """)
    }

    /// A malformed frame arriving mid-scan is a failure immediately, not something to skip past.
    ///
    /// The difference matters: an unmatched *well-formed* response belongs to somebody else and
    /// may be dropped, but bytes that are not a JSON-RPC frame at all mean the peer is not
    /// speaking the protocol, and reading further would be reading a stream we no longer
    /// understand.
    func testAMalformedFrameEndsTheScanRatherThanBeingSkipped() async {
        let (session, _) = self.session(replies: [
            frame("this is not a frame"),
            initializeReply,
        ])

        let result = await session.initialize()
        XCTAssertEqual(result, .failure(.frame(.frameIsNotJSON)))
    }
}
