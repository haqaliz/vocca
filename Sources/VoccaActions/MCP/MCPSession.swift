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

/// One conversation with one MCP server: `initialize`, then `tools/list`, then `tools/call`.
///
/// ## Negotiation is a gate, not a greeting
///
/// A session begins ``Negotiation/pending`` and may be used only once it is
/// ``Negotiation/negotiated``. A server that fails `initialize` leaves it ``Negotiation/refused``
/// — **permanently**, and every later operation is refused *before the request leaves*.
///
/// Both halves of that are load-bearing:
///
/// - **Refused before sending.** Returning a failure after asking anyway would satisfy a caller's
///   error check while this process had already spoken to a peer it has no agreement with. The
///   suite asserts it on the transport's record of what was sent, not on the returned value.
/// - **Permanently.** A refused session cannot be renegotiated by asking again. "Unusable" that
///   can be retried into usefulness is not unusable; it is unusable until the caller loops.
///
/// ## Correlation is by id, and the scan is bounded
///
/// ``MCPTransport`` hands back whatever frame the peer produced next, so each request scans
/// forward for the frame bearing **its** id (``JSONRPCResponse/answers(_:)``). A well-formed
/// response for some other id is discarded — it answers a request this session has already
/// resolved or never made. A frame that is not a valid JSON-RPC response at all ends the scan
/// immediately: an unmatched response belongs to somebody else, but unreadable bytes mean the
/// peer is not speaking the protocol and nothing further from it can be trusted to mean anything.
///
/// The scan is bounded by ``maxFramesScanned``. An unbounded search for a matching id is a
/// hostile peer's cheapest way to hang the process that trusted it.
///
/// ## What this type does NOT do
///
/// It does not conform to `ActionProvider`, and it names none of the action vocabulary. Mapping a
/// tool onto an invocation is the next slice's work, and it has an open design question attached
/// that this slice deliberately does not pre-answer: MCP's `tools/call` takes a name **and** an
/// arguments object, while `ActionInvocation` is deliberately two identifiers and no payload.
/// Building the protocol layer first is what lets that question be decided against a real
/// `tools/call` rather than in the abstract.
public actor MCPSession {

    // MARK: - Constants

    /// The MCP protocol revision this client speaks, and the only one it accepts back.
    ///
    /// Strict on purpose. A server answering with a different revision is refused rather than
    /// accommodated: proceeding on a peer's terms means every later frame is interpreted under a
    /// specification neither side agreed on, and the annotation semantics this layer takes safety
    /// decisions from are exactly the sort of thing revisions change.
    public static let protocolVersion = "2025-06-18"

    /// How this client announces itself in `initialize`.
    public static let clientName = "Vocca"

    /// The client version announced in `initialize`.
    public static let clientVersion = "0.1.0"

    /// How many frames one request will scan past before giving up on being answered.
    ///
    /// Small, because the only legitimate reason to skip a frame is a peer answering out of order
    /// or interleaving something we did not ask for. The number's job is to be finite.
    public static let maxFramesScanned = 8

    // MARK: - State

    /// Where the session is in its one negotiation.
    public enum Negotiation: Sendable, Equatable {
        /// Nothing has been asked yet. The only state from which ``initialize()`` may run.
        case pending
        /// The peer agreed a protocol version. The only state from which anything else may run.
        case negotiated
        /// The peer failed to negotiate. Terminal.
        case refused
    }

    /// The negotiation state. Never returns to ``Negotiation/pending``.
    public private(set) var negotiation: Negotiation = .pending

    private let transport: any MCPTransport
    private let announcedName: String
    private let announcedVersion: String

    /// The next id to mint. Monotonic, so no two live requests can share one.
    private var nextIdentifier = 1

    /// A session over `transport`, announcing itself as `clientName`/`clientVersion`.
    public init(
        transport: any MCPTransport,
        clientName: String = MCPSession.clientName,
        clientVersion: String = MCPSession.clientVersion
    ) {
        self.transport = transport
        self.announcedName = clientName
        self.announcedVersion = clientVersion
    }

    // MARK: - initialize

    /// Negotiates with the peer, once.
    ///
    /// - Returns: The server's declared identity, or the reason the session is now unusable.
    ///   Every failure sets ``negotiation`` to ``Negotiation/refused``, including a transport
    ///   that could not deliver: a peer we could not reach is not a peer we may go on to ask for
    ///   tools.
    public func initialize() async -> Result<MCPServerIdentity, MCPSessionFailure> {
        guard negotiation == .pending else { return .failure(.notNegotiated) }

        let request = JSONRPCRequest(
            id: mintIdentifier(),
            method: "initialize",
            params: [
                "protocolVersion": .string(Self.protocolVersion),
                "capabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string(announcedName), "version": .string(announcedVersion),
                ]),
            ])

        switch await exchange(request) {
        case .failure(let failure):
            return refuse(failure)
        case .success(let result):
            guard case .string(let version)? = result["protocolVersion"] else {
                return refuse(.malformedResult("protocolVersion"))
            }
            guard version == Self.protocolVersion else {
                return refuse(.unsupportedProtocolVersion(version))
            }
            guard case .object(let info)? = result["serverInfo"] else {
                return refuse(.malformedResult("serverInfo"))
            }
            guard case .string(let name)? = info["name"], !name.isEmpty else {
                return refuse(.malformedResult("serverInfo.name"))
            }
            guard case .string(let serverVersion)? = info["version"] else {
                return refuse(.malformedResult("serverInfo.version"))
            }
            negotiation = .negotiated
            return .success(
                MCPServerIdentity(
                    name: name, version: serverVersion, protocolVersion: version))
        }
    }

    // MARK: - tools/list

    /// Asks the peer what it can do.
    ///
    /// - Returns: Every tool the server declared, **or none at all**. A list with one unreadable
    ///   element yields ``MCPSessionFailure/malformedToolList`` rather than the elements that
    ///   happened to parse: a partial list would be presented to a user as the server's whole
    ///   offering, with whatever failed to parse — an annotation among it — invisible.
    ///
    ///   An empty list is a legitimate success. A server with nothing to offer is not a
    ///   malformed one.
    public func listTools() async -> Result<[MCPToolDescriptor], MCPSessionFailure> {
        guard negotiation == .negotiated else { return .failure(.notNegotiated) }

        let request = JSONRPCRequest(id: mintIdentifier(), method: "tools/list")
        switch await exchange(request) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let result):
            guard case .array(let elements)? = result["tools"] else {
                return .failure(.malformedToolList)
            }
            var tools: [MCPToolDescriptor] = []
            tools.reserveCapacity(elements.count)
            for element in elements {
                guard let tool = MCPToolDescriptor.parse(element) else {
                    return .failure(.malformedToolList)
                }
                tools.append(tool)
            }
            return .success(tools)
        }
    }

    // MARK: - tools/call

    /// Runs a tool.
    ///
    /// - Parameters:
    ///   - name: The tool's name, as the server spells it.
    ///   - arguments: The tool's arguments. MCP's `tools/call` takes both, and a call that
    ///     dropped the arguments would run a different action from the one that was asked for.
    /// - Returns: The server's content, or a typed failure. A tool that ran and refused is a
    ///   **success** carrying ``MCPToolCallResult/isError``; collapsing that into a failure would
    ///   lose the only signal that the tool itself was reached at all.
    public func callTool(_ name: String, arguments: [String: JSONValue] = [:]) async -> Result<
        MCPToolCallResult, MCPSessionFailure
    > {
        guard negotiation == .negotiated else { return .failure(.notNegotiated) }

        let request = JSONRPCRequest(
            id: mintIdentifier(),
            method: "tools/call",
            params: ["name": .string(name), "arguments": .object(arguments)])

        switch await exchange(request) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let result):
            guard case .array(let blocks)? = result["content"] else {
                return .failure(.malformedResult("content"))
            }
            var textContent: [String] = []
            for block in blocks {
                guard case .object(let members) = block,
                    case .string(let kind)? = members["type"]
                else {
                    return .failure(.malformedResult("content"))
                }
                // Blocks this layer does not render — images, audio, embedded resources — are
                // skipped rather than refused: a server is entitled to send them, and refusing
                // the whole call would make a picture fatal.
                guard kind == "text" else { continue }
                guard case .string(let text)? = members["text"] else {
                    return .failure(.malformedResult("content"))
                }
                textContent.append(text)
            }
            var isError = false
            if case .bool(let flag)? = result["isError"] { isError = flag }
            return .success(MCPToolCallResult(textContent: textContent, isError: isError))
        }
    }

    // MARK: - The wire

    /// Sends one request and scans forward for the frame that answers it.
    ///
    /// See the type documentation for why the scan skips unmatched responses, stops at
    /// unreadable ones, and is bounded.
    private func exchange(_ request: JSONRPCRequest) async -> Result<
        [String: JSONValue], MCPSessionFailure
    > {
        guard let frame = request.encoded() else { return .failure(.requestNotEncodable) }
        if let failure = await transport.send(frame) { return .failure(.transport(failure)) }

        for _ in 0..<Self.maxFramesScanned {
            switch await transport.receive() {
            case .failure(let failure):
                return .failure(.transport(failure))
            case .success(let reply):
                switch JSONRPCResponse.decode(reply) {
                case .failure(let failure):
                    return .failure(.frame(failure))
                case .success(let response):
                    guard response.answers(request) else { continue }
                    switch response.outcome() {
                    case .failure(let failure): return .failure(.frame(failure))
                    case .success(let result): return .success(result)
                    }
                }
            }
        }
        return .failure(.unanswered)
    }

    /// Records the refusal and returns it — the one place ``negotiation`` becomes terminal, so
    /// that no early return in ``initialize()`` can leave a half-negotiated session usable.
    private func refuse(_ failure: MCPSessionFailure) -> Result<
        MCPServerIdentity, MCPSessionFailure
    > {
        negotiation = .refused
        return .failure(failure)
    }

    private func mintIdentifier() -> JSONRPCID {
        defer { nextIdentifier += 1 }
        return .number(nextIdentifier)
    }
}

/// What a server said it is, after a successful negotiation. Its own claim, like everything else
/// a peer says about itself.
public struct MCPServerIdentity: Sendable, Equatable {
    public let name: String
    public let version: String
    public let protocolVersion: String

    public init(name: String, version: String, protocolVersion: String) {
        self.name = name
        self.version = version
        self.protocolVersion = protocolVersion
    }
}

/// What a tool answered with.
public struct MCPToolCallResult: Sendable, Equatable {

    /// The text blocks the server returned, in order. Block kinds this layer does not render are
    /// skipped, so an empty array can mean "returned nothing" or "returned only pictures".
    public let textContent: [String]

    /// The server's own report that the **tool** failed — which is not the same as the call
    /// failing, and is kept separate for that reason.
    public let isError: Bool

    public init(textContent: [String], isError: Bool) {
        self.textContent = textContent
        self.isError = isError
    }
}

/// Why a session operation did not produce an answer.
public enum MCPSessionFailure: Error, Sendable, Equatable {

    /// The session has not successfully negotiated, or has already tried and been refused. Also
    /// the answer to a second ``MCPSession/initialize()``: negotiation happens once.
    case notNegotiated

    /// The transport could not carry the frame or produce one.
    case transport(MCPTransportFailure)

    /// The peer answered with something that is not a usable JSON-RPC response — including a
    /// well-formed error, which is carried verbatim inside.
    case frame(JSONRPCFailure)

    /// The peer negotiated a protocol revision this client does not speak. Carries the peer's
    /// version, so the refusal can be explained rather than merely reported.
    case unsupportedProtocolVersion(String)

    /// A valid JSON-RPC result that is not a valid result *for this method*. Carries the member
    /// that was wrong — an unnamed parse failure against an untrusted peer is unactionable.
    case malformedResult(String)

    /// A `tools/list` result that could not be read whole. **No tools** — never a partial list.
    case malformedToolList

    /// The peer produced frames but never one bearing this request's id, within the bound.
    case unanswered

    /// The request could not be serialised. Structurally unreachable — every member of a request
    /// comes from a ``JSONValue`` — and present so that encoding failure is a returned value
    /// rather than a force-unwrap.
    case requestNotEncodable
}
