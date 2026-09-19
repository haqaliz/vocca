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

import VoccaCore
import XCTest

/// The action seam: the `ActionProvider` protocol (C13's seam, `action-safety-spine` PRD M1)
/// and its plain-data vocabulary, pinned before either exists.
///
/// Where ``ContextSeamTests`` pinned the context seam's shape and behaviour, this suite pins
/// the action seam's — against the seam itself and its one shipped implementation. **One**
/// implementation ships in this aspect, not two: ``NullActionProvider`` is the shipped default,
/// and every provider that actually does something is a later aspect's (the recording stub is
/// `action-seam`'s Phase 4; any real adapter is out of the whole unit's scope).
///
/// The claims this file makes about the seam as `confirmation-gate` and `audit-log` will find
/// it:
///
/// - `BlastRadius` is a **closed** three-case enum, and the gate has exactly one place to
///   branch: `requiresConfirmation` (PRD M3). The sweep below runs over `allCases`, so a fourth
///   case added later fails here first rather than silently inheriting a default;
/// - an `ActionInvocation` names a provider and a tool, and **refuses empty identifiers at
///   construction** — a nameless action cannot be described concretely, which is what M2 asks
///   the summary sentence to be;
/// - an `ActionSummary` carries the concrete sentence plus the blast radius the gate reads, and
///   compares by value;
/// - an `ActionOutcome` is `.succeeded` / `.failed(reasonKey:)` / `.notInvoked`, and the failure
///   carries a **reason key, never a message** — `VoccaCore` is Foundation-free and the audit
///   entry's byte-level pin has to stay satisfiable, which unbounded error text would break;
/// - the seam splits a pure `describe` from the acting `invoke` (PRD M5a). Both are
///   **`async` and non-throwing**, pinned by use and by unapplied reference: the calls below
///   carry `await` and no `try`, so adding `throws` to either breaks this file. `async` because
///   a provider whose work is asynchronous — an actor-backed store, MCP over stdio, a
///   subprocess — cannot be written against a synchronous witness at all; **not** `async
///   throws`, because failure is a returned ``ActionOutcome`` that the audit log must record
///   either way and that an omitted `catch` must not be able to drop (`async-seam`, 2026-09-19);
/// - ``NullActionProvider`` exposes zero tools and serves nothing.
///
/// ## The one place a test deliberately stops short
///
/// `invoke` is pinned here **by reference, never by call**. `ActionConfirmation`'s initializer
/// is `internal`, so no file in this test target can mint one — that inaccessibility *is* the
/// structural refusal (spec acceptance 3, PRD M4), and a test that could call `invoke` would be
/// a test that had defeated it. The refusal is therefore asserted at the two surfaces a caller
/// can actually reach — the empty tool list and the refusal summary `describe` returns for
/// every tool alike — and the `invoke` leg belongs to `confirmation-gate`, where the gate mints
/// and can drive a provider end to end. This is a recorded stopping point, not an oversight.
final class ActionSeamTests: XCTestCase {

    /// A valid invocation for the shipped default, or a failed test — the vocabulary's
    /// constructor is failable by design and unwrapping it in every test would bury the reason.
    private func makeInvocation(
        providerID: String = "dev.vocca.null", toolID: String = "noop",
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> ActionInvocation {
        try XCTUnwrap(
            ActionInvocation(providerID: providerID, toolID: toolID),
            "a non-empty provider id and tool id must construct an invocation", file: file,
            line: line)
    }

    // MARK: - 1. The blast radius is closed, and the gate branches in one place

    /// `BlastRadius` has exactly three cases and exactly one documented predicate.
    ///
    /// The sweep runs over **all** of `allCases` rather than three hand-written assertions: a
    /// fourth case added later — a `reversible`, say — fails the count here before it can reach
    /// the gate and inherit whichever side of `requiresConfirmation` the `default` branch fell
    /// on. PRD M3 is the contract: read-only may run directly, the other two require
    /// confirmation.
    func testBlastRadiusIsClosedWithOneConfirmationPredicate() {
        XCTAssertEqual(
            BlastRadius.allCases.count, 3,
            "the enum is closed at readOnly / destructive / outwardFacing — a fourth case is a "
                + "reviewed change to the gate's one branch point, never an addition here alone")
        XCTAssertEqual(
            Set(BlastRadius.allCases), [.readOnly, .destructive, .outwardFacing],
            "the three cases are the ones PRD M3 names")

        var swept = 0
        for radius in BlastRadius.allCases {
            swept += 1
            switch radius {
            case .readOnly:
                XCTAssertFalse(
                    radius.requiresConfirmation,
                    "a read-only action may run directly — it is the one case the gate lets past")
            case .destructive, .outwardFacing:
                XCTAssertTrue(
                    radius.requiresConfirmation,
                    "\(radius) changes something or leaves the machine — the gate must stop it")
            }
        }
        XCTAssertEqual(swept, 3, "the sweep saw every case; it did not short-circuit")
    }

    // MARK: - 2. An invocation names a provider and a tool, and refuses to be nameless

    /// An invocation carries `providerID` and `toolID`, and **cannot be built without both**.
    ///
    /// The refusal is at construction, not a validity flag carried alongside: an invocation that
    /// exists is one the audit log can name and the confirmation sentence can be concrete about.
    func testAnInvocationNamesItsProviderAndToolAndRefusesEmptyIdentifiers() throws {
        let invocation = try makeInvocation(providerID: "dev.vocca.shell", toolID: "list-files")
        XCTAssertEqual(invocation.providerID, "dev.vocca.shell")
        XCTAssertEqual(invocation.toolID, "list-files")

        XCTAssertNil(
            ActionInvocation(providerID: "", toolID: "list-files"),
            "a tool without a provider cannot be attributed in the audit log")
        XCTAssertNil(
            ActionInvocation(providerID: "dev.vocca.shell", toolID: ""),
            "a provider without a tool cannot be described concretely")
        XCTAssertNil(
            ActionInvocation(providerID: "", toolID: ""),
            "nameless on both counts is refused for both reasons")
    }

    // MARK: - 3. The summary is the concrete sentence, compared by value

    /// An `ActionSummary` carries the sentence the confirmation will show and the blast radius
    /// the gate will branch on, and two summaries are equal exactly when both parts are.
    ///
    /// Value equality is what lets a later test assert "the sentence the user confirmed is the
    /// sentence the audit log recorded" without reaching into either side's internals.
    func testASummaryCarriesTheConcreteSentenceAndComparesByValue() {
        let sentence = "Delete 3 files in ~/Downloads."
        let first = ActionSummary(sentence: sentence, blastRadius: .destructive)
        let second = ActionSummary(sentence: sentence, blastRadius: .destructive)

        XCTAssertEqual(first.sentence, sentence)
        XCTAssertEqual(first.blastRadius, .destructive)
        XCTAssertEqual(first, second, "equality is value equality, not identity")

        XCTAssertNotEqual(
            first, ActionSummary(sentence: sentence, blastRadius: .readOnly),
            "the same words at a different blast radius is a different summary — the gate reads "
                + "the radius, so conflating them would let a destructive action wear a "
                + "read-only sentence")
        XCTAssertNotEqual(
            first, ActionSummary(sentence: "Delete 2 files in ~/Downloads.", blastRadius: .destructive),
            "the sentence is the concrete claim; a different one is a different summary")
    }

    // MARK: - 4. The outcome is three cases, and failure is a key

    /// `ActionOutcome` is `.succeeded`, `.failed(reasonKey:)` and `.notInvoked`, and the failure
    /// payload is a **key** rather than a message.
    ///
    /// `.notInvoked` is not a kind of failure: it is the record that the provider never acted at
    /// all — declined, refused, or never reached. The audit log needs the two distinguishable,
    /// because "it tried and failed" and "it was never allowed to try" are different events.
    func testAnOutcomeIsSucceededFailedByKeyOrNotInvoked() {
        let outcomes: [ActionOutcome] = [
            .succeeded, .failed(reasonKey: "provider.unknownTool"), .notInvoked,
        ]

        var seen = 0
        for outcome in outcomes {
            seen += 1
            switch outcome {
            case .succeeded:
                XCTAssertEqual(outcome, .succeeded)
            case .failed(let reasonKey):
                XCTAssertEqual(
                    reasonKey, "provider.unknownTool",
                    "the payload is a bounded key, not free-form text that would smuggle "
                        + "unbounded bytes into the audit entry")
            case .notInvoked:
                XCTAssertEqual(outcome, .notInvoked)
            }
        }
        XCTAssertEqual(seen, 3, "all three cases were reached")

        XCTAssertNotEqual(
            ActionOutcome.succeeded, .notInvoked,
            "acting and never acting are different events in the log")
        XCTAssertEqual(ActionOutcome.failed(reasonKey: "a"), .failed(reasonKey: "a"))
        XCTAssertNotEqual(
            ActionOutcome.failed(reasonKey: "a"), .failed(reasonKey: "b"),
            "the reason key is part of the value — two failures for different reasons are not "
                + "the same outcome")
    }

    // MARK: - 5. The seam: a pure describe, an acting invoke

    /// The seam declares both operations, and both are **`async` and non-throwing**.
    ///
    /// Pinned by use *and* by unapplied reference. The `describe` call below carries `await`,
    /// so a protocol that went back to synchronous would break it; both reference types below
    /// spell `async` and omit `throws`, so adding `throws` to either operation breaks this line
    /// too. The no-`throws` half is the load-bearing one: failure is a returned
    /// ``ActionOutcome`` the audit log must record, and an error the caller can drop by
    /// omitting a `catch` is an audit record that can go missing.
    ///
    /// Why both operations and not only the acting one: C13 requires the confirmation sentence
    /// to be concrete — "clear the audit log, 12 entries, permanently" — and a count like that
    /// is a read. A synchronous `describe` forces vague copy, which is the exact failure C13
    /// names.
    ///
    /// `invoke` is pinned **by reference, not by call**: the unapplied method reference below
    /// asserts its exact signature — invocation in, confirmation in, outcome out, `async`, no
    /// `throws` — without minting the confirmation this target deliberately cannot mint. See
    /// this suite's header.
    func testTheSeamSplitsAPureDescribeFromAnActingInvoke() async throws {
        func requireProvider(_ provider: any ActionProvider) -> any ActionProvider { provider }

        let provider = requireProvider(NullActionProvider())
        let invocation = try makeInvocation()

        let summary: ActionSummary = await provider.describe(invocation)
        XCTAssertFalse(
            summary.sentence.isEmpty,
            "describe always renders a concrete sentence — including a refusal's")

        let describing: (ActionInvocation) async -> ActionSummary = provider.describe
        XCTAssertNotNil(
            describing,
            "the pure half suspends and cannot fail — `async`, never `async throws`")

        let acting: (ActionInvocation, ActionConfirmation) async -> ActionOutcome = provider.invoke
        XCTAssertNotNil(
            acting,
            "the only operation that acts takes a confirmation by value and returns an outcome")
    }

    // MARK: - 6. The shipped default serves nothing

    /// ``NullActionProvider`` exposes **zero** tools. The default Vocca ships with can do
    /// nothing, and that is the honest posture until a real provider is wired behind the same
    /// seam (PRD M9).
    func testTheShippedDefaultExposesZeroTools() {
        let provider: any ActionProvider = NullActionProvider()

        XCTAssertTrue(
            provider.toolIDs.isEmpty,
            "the shipped default advertises no tool — there is nothing for an intent layer to "
                + "resolve against")
    }

    // MARK: - 7. The shipped default refuses even a read-only invocation

    /// A `readOnly` invocation of the shipped default still gets a refusal.
    ///
    /// "Read-only runs directly" is a *gate* rule about permission — it is not a promise that
    /// any provider must serve a read-only call. The default serves nothing, and it says so
    /// identically for every tool it is asked about: the two summaries below are equal because
    /// neither describes a real action, which is a behavioural claim rather than a pin on the
    /// refusal's wording.
    ///
    /// The `invoke` half of this refusal is asserted in `confirmation-gate`, for the reason this
    /// suite's header records.
    func testTheShippedDefaultRefusesEvenAReadOnlyInvocation() async throws {
        let provider: any ActionProvider = NullActionProvider()
        let readOnlyLooking = try makeInvocation(toolID: "read-clipboard")
        let otherTool = try makeInvocation(toolID: "delete-everything")

        let summary = await provider.describe(readOnlyLooking)

        XCTAssertEqual(
            summary.blastRadius, .readOnly,
            "a refusal has no blast radius to speak of — nothing will happen, so nothing needs "
                + "confirming")
        XCTAssertFalse(summary.sentence.isEmpty, "the refusal is still a concrete sentence")
        let otherSummary = await provider.describe(otherTool)
        XCTAssertEqual(
            summary, otherSummary,
            "the default serves no tool, so every tool describes identically — the answer is "
                + "about the provider, never about the tool it was handed")
        XCTAssertFalse(
            provider.toolIDs.contains(readOnlyLooking.toolID),
            "the read-only tool is not one the default claims to serve")
    }

    // MARK: - 8. The whole vocabulary crosses isolation boundaries

    /// Every type in the seam's vocabulary is `Sendable`, asserted by **use inside a
    /// `@Sendable` closure** — the values below are captured and read there, which is a compile
    /// obligation the house never satisfies with `@unchecked`.
    ///
    /// `ActionConfirmation` is asserted at the type level instead of by capture: this target
    /// cannot mint one, which is the point of its `internal` initializer.
    func testTheWholeVocabularyIsSendable() throws {
        func requireSendableType<T: Sendable>(_ type: T.Type) { _ = type }

        let invocation = try makeInvocation(providerID: "dev.vocca.stub", toolID: "tick")
        let summary = ActionSummary(sentence: "Nothing will happen.", blastRadius: .readOnly)
        let outcome = ActionOutcome.notInvoked
        let radius = BlastRadius.outwardFacing
        let provider: any ActionProvider = NullActionProvider()

        requireSendableType(ActionConfirmation.self)

        let crossing: @Sendable () -> String = {
            "\(invocation.providerID)/\(invocation.toolID)|\(summary.blastRadius)|"
                + "\(outcome == .notInvoked)|\(radius.requiresConfirmation)|\(provider.toolIDs.count)"
        }

        XCTAssertEqual(crossing(), "dev.vocca.stub/tick|readOnly|true|true|0")
    }

    // MARK: - 9. Arguments: the opaque JSON text an invocation may carry (`mcp-provider`)

    /// An invocation carries **optional argument text**, and carries none by default.
    ///
    /// MCP's `tools/call` takes a name *and* an arguments object, so the two-identifier
    /// vocabulary could not express one at all (`mcp-protocol` card, "the vocabulary may not
    /// survive contact"). The field is a `String` because `VoccaCore` imports nothing — there is
    /// no `Data` and no JSON type to hold here — and it defaults to `nil` so every construction
    /// site written before MCP existed keeps compiling and keeps meaning what it meant.
    func testAnInvocationCarriesOptionalArgumentTextAndCarriesNoneByDefault() throws {
        let plain = try makeInvocation(providerID: "dev.vocca.mcp", toolID: "send-message")
        XCTAssertNil(
            plain.arguments,
            "absent is the default — a caller that says nothing about arguments has not supplied "
                + "any, and the field is purely additive to every site that predates it")

        let payload = ##"{"channel":"#general","text":"ship it"}"##
        let carrying = try XCTUnwrap(
            ActionInvocation(
                providerID: "dev.vocca.mcp", toolID: "send-message", arguments: payload),
            "an invocation carrying well-formed argument text must construct")
        XCTAssertEqual(
            carrying.arguments, payload,
            "the text is carried verbatim — `VoccaCore` cannot parse it, so it cannot normalise "
                + "it either, and a value the core rewrote would not be the value the user was "
                + "asked about")
    }

    /// **Absence has one spelling.** Empty argument text is refused at construction, the same way
    /// an empty identifier is.
    ///
    /// Not JSON validation — the core has nothing to validate with — but the same emptiness rule
    /// the identifiers already carry: two representations of "no arguments" would be two things
    /// every downstream consumer has to treat alike, which is the shape in which one of them
    /// eventually does not.
    func testEmptyArgumentTextIsRefusedSoAbsenceHasOneSpelling() {
        XCTAssertNil(
            ActionInvocation(providerID: "dev.vocca.mcp", toolID: "send-message", arguments: ""),
            "empty argument text is not 'no arguments' spelled a second way — it is refused, so "
                + "`nil` is the only way to say an invocation carries none")
    }

    /// Equality **includes** the arguments: two invocations of the same tool with different
    /// argument text are different invocations.
    ///
    /// Load-bearing rather than incidental. ``ActionEnablement`` membership and the gate's
    /// per-invocation reasoning are both by whole ``ActionInvocation``, so an equality that
    /// ignored arguments would let one enabled call authorise a different call to the same tool.
    func testEqualityDistinguishesInvocationsByTheirArgumentText() throws {
        let toGeneral = try XCTUnwrap(
            ActionInvocation(
                providerID: "dev.vocca.mcp", toolID: "send-message",
                arguments: ##"{"channel":"#general"}"##))
        let toIncidents = try XCTUnwrap(
            ActionInvocation(
                providerID: "dev.vocca.mcp", toolID: "send-message",
                arguments: ##"{"channel":"#incidents"}"##))
        let bare = try makeInvocation(providerID: "dev.vocca.mcp", toolID: "send-message")

        XCTAssertNotEqual(
            toGeneral, toIncidents,
            "same tool, different arguments, different action — an equality blind to the payload "
                + "would let an enablement for one message authorise another")
        XCTAssertNotEqual(
            toGeneral, bare,
            "carrying arguments is not the same invocation as carrying none")
        XCTAssertEqual(
            toGeneral,
            ActionInvocation(
                providerID: "dev.vocca.mcp", toolID: "send-message",
                arguments: ##"{"channel":"#general"}"##),
            "equality is by value throughout, arguments included")
    }

    /// The bound is enforced **at construction**, at the boundary and one byte over.
    ///
    /// An unbounded blob travelling through the gate is a needless liability even though nothing
    /// persists it: it reaches a confirmation sentence a person is asked to read, and it is text
    /// chosen by an intent layer over an untrusted server's schema.
    ///
    /// **Refusal, not truncation** — and the difference matters more here than it does for
    /// ``ActionAuditEntry``'s summary, which truncates. A truncated *sentence* is a shorter
    /// account of the same action; truncated *arguments* are a different action, quietly. The
    /// bound is measured in UTF-8 bytes, so a multi-byte payload is bounded by the same number of
    /// bytes rather than by a larger number of characters.
    func testArgumentTextIsBoundedAtTheBoundaryAndRefusedOneByteOver() throws {
        let bound = ActionInvocation.maximumArgumentsUTF8Bytes
        XCTAssertGreaterThan(bound, 0, "vacuity guard: the bound must be a real number of bytes")

        let atBound = String(repeating: "a", count: bound)
        XCTAssertEqual(atBound.utf8.count, bound, "vacuity guard: the payload is exactly the bound")
        let accepted = try XCTUnwrap(
            ActionInvocation(
                providerID: "dev.vocca.mcp", toolID: "send-message", arguments: atBound),
            "argument text of exactly the bound is accepted — the boundary is inclusive")
        XCTAssertEqual(accepted.arguments?.utf8.count, bound)

        let overBound = String(repeating: "a", count: bound + 1)
        XCTAssertNil(
            ActionInvocation(
                providerID: "dev.vocca.mcp", toolID: "send-message", arguments: overBound),
            "one byte over is refused at construction — truncating arguments would run a "
                + "different action from the one that was asked for")

        let multiByte = String(repeating: "\u{00e9}", count: bound / 2 + 1)
        XCTAssertEqual(
            multiByte.utf8.count, bound + 2,
            "vacuity guard: the multi-byte payload really is over the bound in BYTES while being "
                + "well under it in characters")
        XCTAssertNil(
            ActionInvocation(
                providerID: "dev.vocca.mcp", toolID: "send-message", arguments: multiByte),
            "the bound is bytes, not characters — a payload under the bound in characters and "
                + "over it in bytes is still over it")
    }
}
