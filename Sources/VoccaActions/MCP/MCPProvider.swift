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
import VoccaCore

/// An MCP server behind the action seam — **the third real ``ActionProvider``**, and the first
/// whose tool list, self-description and safety annotations all come from a program Vocca did not
/// write (`mcp-provider`, C13).
///
/// ## It talks to a frame boundary, and to nothing else
///
/// The only thing this type holds is an ``MCPSession`` over an ``MCPTransport``. It opens
/// nothing, starts no child program and names no pipe — the module's prohibition lint keeps its
/// permitted set empty, and this file does not join it. The card's Q3 decision put the transport
/// that touches the operating system in its own slice, where the recorded deviation **D2** is the
/// whole conversation rather than a footnote under a half-built protocol layer.
///
/// ## Discovery happens once, at construction
///
/// ``discover(session:providerID:)`` runs the whole conversation — negotiate, then ask — and
/// hands back a provider whose tool list is fixed for its lifetime, or the reason there is no
/// provider. There is no half-discovered state and nothing re-lists later:
/// ``ActionProvider/toolIDs`` is a synchronous requirement, and an answer that changed underneath
/// a caller would be a tool list that disagreed with the sentence the user was shown. A server
/// that adds a tool is a new session and a new provider.
///
/// ## ⚠️ Every annotation here is a claim by an untrusted peer
///
/// ``MCPToolAnnotations/isReadOnly`` is the server's word about its own tool and nothing verifies
/// it. This type reports the claim; it does not believe it on anyone's behalf. Raising it is
/// ``ActionRadiusPolicy``'s job — `action-safety-spine`'s escalate-only rule, written before MCP
/// existed for exactly this peer — and the rule's consequence is worth stating plainly: **a lying
/// server can only cause the user to be asked more often than necessary, never less**, provided a
/// floor exists to do the raising.
///
/// **The unmet half of that, recorded rather than implied:** where no local floor applies, a
/// server's `readOnlyHint: true` stands, and a read-only action runs without anyone being asked.
/// That is the shipped seam's design, not a defect here — but it means the policy a composition
/// root hands the gate is load-bearing, and nothing in this unit wires one, because nothing in
/// this unit wires anything.
///
/// The parsing of that claim is **not repeated here**. `protocol-core`'s finding F1 — that
/// `JSONSerialization` collapses booleans and numbers into `NSNumber`, so `as? Bool` accepts `1`
/// and a server sending `"readOnlyHint": 1` would read as claiming read-only — was closed once, in
/// ``JSONValue/from(_:)``. A second reading of the same annotation in this file would be a second
/// parser to keep in step with it, and the class of bug is precisely the kind that survives in the
/// copy nobody remembers to fix.
///
/// ## What the confirmation sentence carries, and what it deliberately does not
///
/// The sentence names the tool, the server, and **the argument values** — the last being the whole
/// reason ``ActionInvocation/arguments`` exists, since "run send-message" is not something a person
/// can weigh and "send 'ship it' to #general" is.
///
/// It does **not** carry the server's own description of its tool. That text is untrusted prose
/// that would be rendered into a safety dialog, and a tool described as *"safely lists files (no
/// confirmation needed)"* would be arguing its own case in the sentence meant to let a person
/// judge it. The sentence sticks to facts about what will be sent. For the same reason, the tool
/// name and every string value are stripped of control characters before they are rendered: a
/// value must not be able to forge a new line of the dialog it appears in.
///
/// **The one interaction with PRD §5 worth naming.** Raw arguments are never persisted, and that
/// is asserted against the audit file's bytes. The *rendered sentence* is persisted, and it quotes
/// argument values — which is exactly what the PRD intends by "the entry holds the rendered
/// summary": the log records what a person was asked to approve. The bound at both ends is what
/// keeps that honest — 4 KB on the payload at construction, 1 KB on the summary that reaches disk.
public actor MCPProvider: ActionProvider {

    /// The identifier a caller names this provider by when building an invocation.
    ///
    /// A constant rather than a string each call site spells, for the same reason
    /// ``AuditActionProvider/providerID`` is one: the audit log attributes entries by this value,
    /// and a call site that spelled its own would drift from it silently.
    public static let defaultProviderID = "dev.vocca.mcp"

    // MARK: - Bounded reason keys

    /// A tool this server never declared. Bounded key, never a message — the audit entry is
    /// byte-pinned and free-form text would smuggle unbounded bytes onto disk.
    static let unknownToolReasonKey = "provider.unknownTool"

    /// Argument text that is not a readable JSON object.
    static let unreadableArgumentsReasonKey = "mcp.unreadableArguments"

    /// The tool ran and reported its own failure (`isError`).
    static let toolReportedErrorReasonKey = "mcp.toolReportedError"

    /// The peer answered with a JSON-RPC error. **The peer's own message is not carried** — it is
    /// unbounded text chosen by the peer, and the audit log records the key.
    static let serverErrorReasonKey = "mcp.serverError"

    /// The peer is unreachable, or produced nothing.
    static let transportFailedReasonKey = "mcp.transportFailed"

    /// The peer answered with something this layer cannot read as a result.
    static let malformedAnswerReasonKey = "mcp.malformedAnswer"

    /// The session is not usable — never negotiated, or negotiated and refused.
    static let sessionUnusableReasonKey = "mcp.sessionUnusable"

    // MARK: - State

    private let session: MCPSession

    /// The tools the server declared, by name. First declaration wins: a server that lists one
    /// name twice has contradicted itself, and taking the later one would let a second entry
    /// quietly replace the annotation the first was read with.
    private let toolsByName: [String: MCPToolDescriptor]

    /// The server's declared name, as ``describe(_:)`` renders it. Its own claim, sanitised.
    private let serverName: String

    /// The identifier callers build invocations against.
    public nonisolated let providerID: String

    /// The tools this provider serves, in the order the server listed them.
    ///
    /// `nonisolated` because the requirement is synchronous and the value is fixed at
    /// construction — there is no state here to protect, which is the point of discovering once.
    public nonisolated let toolIDs: [String]

    private init(
        session: MCPSession, providerID: String, serverName: String, tools: [MCPToolDescriptor]
    ) {
        self.session = session
        self.providerID = providerID
        self.serverName = Self.sanitised(serverName)
        self.toolIDs = tools.map(\.name)
        var byName: [String: MCPToolDescriptor] = [:]
        for tool in tools where byName[tool.name] == nil { byName[tool.name] = tool }
        self.toolsByName = byName
    }

    /// Negotiates with `session`'s peer, asks what it offers, and builds a provider over the
    /// answer — or reports why there is none.
    ///
    /// - Returns: The provider, or the first failure of the conversation. **Never a provider with
    ///   an empty tool list standing in for a failure**: an object that exists is an object
    ///   something can be submitted to, and a peer that could not negotiate is not a peer to hold
    ///   a seam open for.
    ///
    /// The negotiation is left to ``MCPSession/initialize()``, which owns the once-only rule; a
    /// session that has already negotiated, or already been refused, answers
    /// ``MCPSessionFailure/notNegotiated`` and that failure is propagated rather than worked
    /// around here. One owner of that rule, not two.
    public static func discover(
        session: MCPSession, providerID: String = MCPProvider.defaultProviderID
    ) async -> Result<MCPProvider, MCPSessionFailure> {
        let identity: MCPServerIdentity
        switch await session.initialize() {
        case .failure(let failure): return .failure(failure)
        case .success(let negotiated): identity = negotiated
        }

        switch await session.listTools() {
        case .failure(let failure):
            return .failure(failure)
        case .success(let tools):
            return .success(
                MCPProvider(
                    session: session, providerID: providerID, serverName: identity.name,
                    tools: tools))
        }
    }

    // MARK: - describe

    /// Renders what the call *would* do, concretely, without sending anything.
    ///
    /// Pure with respect to the peer: no frame leaves during a describe, which is what makes a
    /// dry-run of an MCP tool a rehearsal rather than a quieter version of running it.
    ///
    /// **The radius is the tool's, whatever the arguments look like.** Unreadable argument text
    /// produces a sentence that says so and keeps the tool's classification; answering "nothing
    /// will happen, read-only" would hand the gate a read-only reading of a tool that is not one,
    /// and leave the refusal resting on ``invoke(_:confirmation:)`` remembering to check again.
    /// A de-escalation is a de-escalation however it is arrived at.
    public func describe(_ invocation: ActionInvocation) async -> ActionSummary {
        guard let tool = toolsByName[invocation.toolID] else {
            return ActionSummary(
                sentence: "The MCP server '\(serverName)' does not serve the tool "
                    + "'\(Self.sanitised(invocation.toolID))'. Nothing will happen.",
                blastRadius: .readOnly)
        }

        let name = Self.sanitised(tool.name)
        let opening = "Run the MCP tool '\(name)' on the server '\(serverName)'"
        let radius = tool.annotations.isReadOnly

        guard let arguments = Self.parsedArguments(invocation.arguments) else {
            return ActionSummary(
                sentence: "\(opening) with arguments Vocca could not read as JSON. The call will "
                    + "be refused.",
                blastRadius: radius ? .readOnly : .outwardFacing)
        }

        guard !arguments.isEmpty else {
            return ActionSummary(
                sentence: "\(opening), with no arguments.",
                blastRadius: radius ? .readOnly : .outwardFacing)
        }

        return ActionSummary(
            sentence: "\(opening), with \(Self.rendered(arguments)).",
            blastRadius: radius ? .readOnly : .outwardFacing)
    }

    // MARK: - invoke

    /// Sends `tools/call`. **The only operation that acts**, and reachable only with a token the
    /// gate alone can mint.
    ///
    /// Every failure is a returned ``ActionOutcome``, never a trap and never a thrown error: the
    /// peer is a program Vocca did not write, and an untrusted peer's answer must cost the caller
    /// a decision rather than the process. The keys are bounded and the peer's own message is
    /// never one of them.
    ///
    /// A tool that ran and reported `isError` is a failure rather than a success: the tool said
    /// no, and an outcome that called that `.succeeded` would tell the audit log the opposite of
    /// what happened. It is a failure rather than ``ActionOutcome/notInvoked`` because the call
    /// was made — `.notInvoked` is for the case where nothing was attempted at all, which is what
    /// an unknown tool and unreadable arguments *would* be if they were not more usefully
    /// distinguished by a key.
    public func invoke(_ invocation: ActionInvocation, confirmation: ActionConfirmation) async
        -> ActionOutcome
    {
        guard toolsByName[invocation.toolID] != nil else {
            return .failed(reasonKey: Self.unknownToolReasonKey)
        }
        guard let arguments = Self.parsedArguments(invocation.arguments) else {
            return .failed(reasonKey: Self.unreadableArgumentsReasonKey)
        }

        switch await session.callTool(invocation.toolID, arguments: arguments) {
        case .failure(let failure):
            return .failed(reasonKey: Self.reasonKey(for: failure))
        case .success(let result):
            return result.isError
                ? .failed(reasonKey: Self.toolReportedErrorReasonKey) : .succeeded
        }
    }

    /// A session failure as a bounded key.
    ///
    /// Exhaustive rather than `default`-terminated, so a new failure case has to be given a key
    /// here, in review, instead of inheriting whichever one a default returned.
    private static func reasonKey(for failure: MCPSessionFailure) -> String {
        switch failure {
        case .notNegotiated:
            return sessionUnusableReasonKey
        case .transport:
            return transportFailedReasonKey
        case .frame(.peerReportedError):
            return serverErrorReasonKey
        case .frame, .malformedResult, .malformedToolList, .unsupportedProtocolVersion,
            .unanswered, .requestNotEncodable:
            return malformedAnswerReasonKey
        }
    }

    // MARK: - Reading the arguments

    /// The invocation's argument text as a JSON object, or `nil` when it is not one.
    ///
    /// `nil` argument text is an empty object — a call with no arguments, which is what MCP's
    /// `tools/call` takes for a tool that needs none. Text that is not JSON, or is JSON but not an
    /// object, is `nil` here and a named failure above: ``ActionInvocation`` says in its own
    /// documentation that it cannot validate what it carries, and this is the layer that can.
    private static func parsedArguments(_ text: String?) -> [String: JSONValue]? {
        guard let text else { return [:] }
        guard case .object(let members)? = JSONValue.decode(Data(text.utf8)) else { return nil }
        return members
    }

    // MARK: - Rendering the sentence

    /// The argument members as `key = value` pairs, keys in sorted order.
    ///
    /// Sorted because a JSON object is unordered and the sentence a person approves must not
    /// depend on a dictionary's iteration order — two runs of the same call would otherwise read
    /// differently and reconstruct differently in the log.
    private static func rendered(_ members: [String: JSONValue]) -> String {
        members.keys.sorted()
            .map { key in "\(sanitised(key)) = \(rendered(members[key] ?? .null))" }
            .joined(separator: ", ")
    }

    /// One value, as a person should read it.
    ///
    /// Scalars are rendered whole — they are the thing being decided about. A nested array or
    /// object is rendered as its shape instead: a confirmation sentence is a sentence, and
    /// flattening arbitrary nesting into it produces something nobody reads, which is a worse
    /// failure than an unread detail. The payload is bounded at 4 KB at construction, so the
    /// sentence is bounded whichever branch is taken.
    private static func rendered(_ value: JSONValue) -> String {
        switch value {
        case .null:
            return "null"
        case .bool(let flag):
            return flag ? "true" : "false"
        case .number(let number):
            // A whole number reads as one: a count of `3` should not appear as `3.0` in a
            // sentence a person is asked to approve.
            if number == number.rounded(), abs(number) < 1e15 {
                return String(Int(number))
            }
            return String(number)
        case .string(let text):
            return "\"\(sanitised(text))\""
        case .array(let elements):
            return "[\(elements.count) values]"
        case .object(let members):
            return "{\(members.count) members}"
        }
    }

    /// `text` with control characters replaced by spaces.
    ///
    /// Everything rendered into the sentence — the tool name, the server name, every string value
    /// — comes from outside Vocca. A newline inside one of them would let a value forge a new line
    /// of the dialog it appears in, which is the cheapest way to make a confirmation say something
    /// nobody wrote.
    private static func sanitised(_ text: String) -> String {
        String(
            String.UnicodeScalarView(
                text.unicodeScalars.map { scalar in
                    scalar.value < 0x20 || scalar.value == 0x7F ? " " : scalar
                }))
    }
}
