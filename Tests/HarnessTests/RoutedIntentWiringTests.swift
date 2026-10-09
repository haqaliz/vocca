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
import VoccaBootstrap
import VoccaCore
import XCTest

// MARK: - The doubles

/// One dispatched call, as the stub's `performAction` saw it.
private struct DispatchedCall: Equatable {
    let providerID: String
    let toolID: String
    let utterance: String
}

/// The stub wiring's call log — main-actor state, so the `@Sendable @MainActor` stub closures
/// may capture it without a lock.
@MainActor
private final class DispatchSpy {
    private(set) var calls: [DispatchedCall] = []

    func record(_ invocation: ActionInvocation, _ utterance: String) {
        calls.append(
            DispatchedCall(
                providerID: invocation.providerID, toolID: invocation.toolID,
                utterance: utterance))
    }
}

/// The lazy agent slot — the root's `agentIntentWiring` shape, test-side: assigned after the
/// router is built, read by the router at call time.
@MainActor
private final class AgentSlot {
    var wiring: IntentWiring<CodingAgentProvider>?
}

// MARK: - The suite

/// **The intent router** (`intent-provider-routing` / `provider-dispatch` R1, R2):
/// `AppBootstrap.routeIntentWiring(audit:agent:)` dispatches a resolved `.toolCall` by its
/// providerID — `vocca.agent` with a composed agent wiring reaches the agent wiring; every
/// other call (the agent side absent, the audit tools, shell, an unknown provider) reaches the
/// audit wiring, whose provider fails an unserved provider closed.
///
/// The wirings are stubs built from the public memberwise init with counting `performAction`
/// closures; the executors are real but never reached by the router (it forwards the audit
/// one, compared by identity).
@MainActor
final class RoutedIntentWiringTests: XCTestCase {

    private static let auditReply = "audit-reply"
    private static let agentReply = "agent-reply"

    private var directory: URL!
    private var auditStore: FileSystemActionAuditStore!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-routed-intent-wiring-\(UUID().uuidString)")
        auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The audit-side stub: counts into `spy`, answers `reply`, resolves to `resolution`.
    private func auditStub(
        spy: DispatchSpy, reply: String? = RoutedIntentWiringTests.auditReply,
        resolution: IntentResolution = .none, policy: ActionRadiusPolicy = .none,
        spawnsSubprocess: Bool = false
    ) -> IntentWiring<AuditActionProvider> {
        IntentWiring(
            resolve: { _ in resolution },
            performAction: { invocation, utterance in
                spy.record(invocation, utterance)
                return reply
            },
            executor: ActionExecutor(
                provider: AuditActionProvider(store: auditStore), store: auditStore),
            policy: policy,
            spawnsSubprocess: spawnsSubprocess)
    }

    /// The agent-side stub: counts into `spy`, answers `reply`. Its resolver must never be the
    /// router's — it answers a distinct question.
    private func agentStub(
        spy: DispatchSpy, reply: String? = RoutedIntentWiringTests.agentReply,
        spawnsSubprocess: Bool = false
    ) -> IntentWiring<CodingAgentProvider> {
        let provider = CodingAgentProvider(
            agents: [],
            run: { _ in
                ShellExecutionResult(
                    status: .succeeded(exitCode: 0),
                    standardOutput: Data(), standardError: Data(), outputWasTruncated: false)
            })
        return IntentWiring(
            resolve: { _ in .ask(question: "agent-side resolver") },
            performAction: { invocation, utterance in
                spy.record(invocation, utterance)
                return reply
            },
            executor: ActionExecutor(provider: provider, store: auditStore),
            policy: .none,
            spawnsSubprocess: spawnsSubprocess)
    }

    private func invocation(_ providerID: String, _ toolID: String) throws -> ActionInvocation {
        try XCTUnwrap(ActionInvocation(providerID: providerID, toolID: toolID))
    }

    // MARK: - R1: dispatch by providerID

    /// **`vocca.agent` with the agent side composed reaches the agent wiring** — the audit
    /// wiring is never called and its reply is never the answer.
    func testAnAgentCallWithTheAgentSideComposedReachesTheAgentWiring() async throws {
        let auditSpy = DispatchSpy()
        let agentSpy = DispatchSpy()
        let agent = agentStub(spy: agentSpy)
        let router = AppBootstrap.routeIntentWiring(
            audit: auditStub(spy: auditSpy), agent: { agent })

        let reply = await router.performAction(
            try invocation(CodingAgentProvider.providerID, "commit-helper"), "fix the tests")

        XCTAssertEqual(reply, Self.agentReply)
        XCTAssertEqual(
            agentSpy.calls,
            [DispatchedCall(
                providerID: CodingAgentProvider.providerID, toolID: "commit-helper",
                utterance: "fix the tests")])
        XCTAssertEqual(auditSpy.calls, [])
    }

    /// **`vocca.agent` with the agent side absent reaches the audit wiring** (Q3) — whose
    /// provider fails the unserved provider closed, audited.
    func testAnAgentCallWithTheAgentSideAbsentReachesTheAuditWiring() async throws {
        let auditSpy = DispatchSpy()
        let router = AppBootstrap.routeIntentWiring(
            audit: auditStub(spy: auditSpy), agent: { nil })

        let reply = await router.performAction(
            try invocation(CodingAgentProvider.providerID, "commit-helper"), "fix the tests")

        XCTAssertEqual(reply, Self.auditReply)
        XCTAssertEqual(
            auditSpy.calls,
            [DispatchedCall(
                providerID: CodingAgentProvider.providerID, toolID: "commit-helper",
                utterance: "fix the tests")])
    }

    /// **The audit tools, shell and an unknown provider all reach the audit wiring** — even
    /// with the agent side composed; the agent wiring is never called.
    func testEveryNonAgentProviderReachesTheAuditWiring() async throws {
        let cases: [(String, String)] = [
            (AuditActionProvider.providerID, AuditActionProvider.countToolID),
            (AuditActionProvider.providerID, AuditActionProvider.clearToolID),
            (ShellProvider.providerID, "list-files"),
            ("dev.example.unknown", "anything"),
            // The match is exact: a case or whitespace variant of the agent id is not the
            // agent provider, and falls to the audit wiring, which fails it closed.
            ("VOCCA.AGENT", "commit-helper"),
            ("vocca.agent ", "commit-helper"),
        ]
        for (providerID, toolID) in cases {
            let auditSpy = DispatchSpy()
            let agentSpy = DispatchSpy()
            let agent = agentStub(spy: agentSpy)
            let router = AppBootstrap.routeIntentWiring(
                audit: auditStub(spy: auditSpy), agent: { agent })

            let reply = await router.performAction(try invocation(providerID, toolID), "words")

            XCTAssertEqual(reply, Self.auditReply, "\(providerID)/\(toolID)")
            XCTAssertEqual(
                auditSpy.calls,
                [DispatchedCall(providerID: providerID, toolID: toolID, utterance: "words")],
                "\(providerID)/\(toolID)")
            XCTAssertEqual(agentSpy.calls, [], "\(providerID)/\(toolID)")
        }
    }

    /// **The reply passes through unchanged, nil included** — the converse wrapper reads nil
    /// as "maybe a card is up"; a router that invented a line would break that detection.
    func testTheReplyPassesThroughUnchangedIncludingNil() async throws {
        let agent = agentStub(spy: DispatchSpy(), reply: nil)
        let router = AppBootstrap.routeIntentWiring(
            audit: auditStub(spy: DispatchSpy(), reply: nil), agent: { agent })

        let agentReply = await router.performAction(
            try invocation(CodingAgentProvider.providerID, "commit-helper"), "u")
        let auditReply = await router.performAction(
            try invocation(AuditActionProvider.providerID, AuditActionProvider.countToolID), "u")

        XCTAssertNil(agentReply)
        XCTAssertNil(auditReply)
    }

    /// **Each branch passes its own reply through** — one side answers nil, the other a line,
    /// and the reverse: the two branches are distinguishable, and neither borrows the other's.
    func testEachBranchPassesItsOwnReplyThrough() async throws {
        let agentCall = try invocation(CodingAgentProvider.providerID, "commit-helper")
        let auditCall = try invocation(
            AuditActionProvider.providerID, AuditActionProvider.countToolID)

        let nilAgent = agentStub(spy: DispatchSpy(), reply: nil)
        let lineAudit = AppBootstrap.routeIntentWiring(
            audit: auditStub(spy: DispatchSpy(), reply: "x"), agent: { nilAgent })
        let agentNil = await lineAudit.performAction(agentCall, "u")
        let auditX = await lineAudit.performAction(auditCall, "u")
        XCTAssertNil(agentNil, "the agent branch's nil is not replaced by the audit's line")
        XCTAssertEqual(auditX, "x")

        let lineAgent = agentStub(spy: DispatchSpy(), reply: "x")
        let nilAudit = AppBootstrap.routeIntentWiring(
            audit: auditStub(spy: DispatchSpy(), reply: nil), agent: { lineAgent })
        let agentX = await nilAudit.performAction(agentCall, "u")
        let auditNil = await nilAudit.performAction(auditCall, "u")
        XCTAssertEqual(agentX, "x")
        XCTAssertNil(auditNil, "the audit branch's nil is not replaced by the agent's line")
    }

    // MARK: - R1: the forwarded members

    /// **`resolve`, `executor` and `policy` are the audit wiring's** — never the agent's.
    func testResolveExecutorAndPolicyAreTheAuditWirings() async throws {
        let floorInvocation = try invocation(
            AuditActionProvider.providerID, AuditActionProvider.countToolID)
        let policy = ActionRadiusPolicy(
            [ActionRadiusPolicy.Floor(invocation: floorInvocation, radius: .destructive)])
        let audit = auditStub(
            spy: DispatchSpy(), resolution: .toolCall(floorInvocation), policy: policy)
        let agent = agentStub(spy: DispatchSpy())
        let router = AppBootstrap.routeIntentWiring(audit: audit, agent: { agent })

        let resolution = await router.resolve("count the log")

        XCTAssertEqual(resolution, .toolCall(floorInvocation))
        XCTAssertTrue(router.executor === audit.executor)
        XCTAssertEqual(router.policy, policy)
    }

    /// **`spawnsSubprocess` is the declared `false`** — even when both stubs claim `true`.
    func testSpawnsSubprocessIsFalseEvenWhenTheStubsClaimTrue() {
        let agent = agentStub(spy: DispatchSpy(), spawnsSubprocess: true)
        let router = AppBootstrap.routeIntentWiring(
            audit: auditStub(spy: DispatchSpy(), spawnsSubprocess: true), agent: { agent })

        XCTAssertFalse(router.spawnsSubprocess)
    }

    // MARK: - R2: the agent side is read lazily

    /// **A router built before the agent slot is assigned dispatches to it after** — the
    /// launch-task ordering: `configure` builds the router, the agent wiring lands later.
    func testARouterBuiltBeforeTheAgentSlotIsAssignedDispatchesToItAfter() async throws {
        let auditSpy = DispatchSpy()
        let agentSpy = DispatchSpy()
        let slot = AgentSlot()
        let router = AppBootstrap.routeIntentWiring(
            audit: auditStub(spy: auditSpy), agent: { slot.wiring })

        slot.wiring = agentStub(spy: agentSpy)
        let reply = await router.performAction(
            try invocation(CodingAgentProvider.providerID, "commit-helper"), "late")

        XCTAssertEqual(reply, Self.agentReply)
        XCTAssertEqual(agentSpy.calls.count, 1)
        XCTAssertEqual(auditSpy.calls, [])
    }

    /// **The slot is read on every call** — cleared after a dispatch, the next agent call falls
    /// back to the audit wiring.
    func testTheAgentSlotIsReadOnEveryCall() async throws {
        let auditSpy = DispatchSpy()
        let agentSpy = DispatchSpy()
        let slot = AgentSlot()
        slot.wiring = agentStub(spy: agentSpy)
        let router = AppBootstrap.routeIntentWiring(
            audit: auditStub(spy: auditSpy), agent: { slot.wiring })
        let call = try invocation(CodingAgentProvider.providerID, "commit-helper")

        _ = await router.performAction(call, "first")
        slot.wiring = nil
        _ = await router.performAction(call, "second")

        XCTAssertEqual(agentSpy.calls.map(\.utterance), ["first"])
        XCTAssertEqual(auditSpy.calls.map(\.utterance), ["second"])
    }
}
