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
import XCTest

@testable import VoccaBootstrap

/// **The readiness latch, made two-way — and the closed set of things that may open it.**
///
/// `EngineReadiness` is the one flag standing between a hotkey press and an open microphone: while
/// it reads `false`, `EngineReadinessGate.beginCapture()` answers `.unavailable`, the machine
/// refuses honestly and the router shows the `.modelUnavailable` notice
/// (`AppBootstrap.swift` — "the mic never opens"). Until this aspect it could only ever be *opened*:
/// `markReady()` and nothing else, which was correct while one process ran exactly one engine
/// forever.
///
/// The engine can now be switched at runtime, and a switch must **close** the gate again — the
/// engine that was prepared is not the engine now selected. So the type gains two transitions back:
/// `markPreparing()` for a wait that is under way, and `markUnavailable()` for one that failed or
/// never started. The gate itself cannot tell them apart — both are closed — but the surfaces that
/// tell a person about it must, which is what `EngineReadinessState` is for.
///
/// ## Why closing needs no safety argument and opening does
///
/// Closing is always safe. A closed gate refuses a press before the microphone is asked for, the
/// user gets an honest notice, and nothing is captured into a void. The worst a spurious close can
/// do is make the user wait. Opening is the dangerous direction: a gate opened over an engine that
/// is not prepared routes a real recording into a pipeline that cannot transcribe it, which is the
/// one thing the readiness gate exists to prevent.
///
/// That asymmetry is why ``testMarkReadyIsTheOnlyOpenerOfTheGate`` is written as a scan of the
/// shipped source rather than as a behavioural check: a behavioural test can only exercise the
/// openers it already knows about, and the risk here is a *new* one being added. The scan makes
/// adding one a deliberate act that has to edit this file.
///
/// `@MainActor` because both types are confined to it by use — the annotation is illegal on them
/// (they conform to the nonisolated `SessionAudioSource` seam), and the confinement is documented
/// at their declarations.
@MainActor
final class EngineReadinessTests: XCTestCase {

    // MARK: - The transition back

    /// **Phase 1, row 1.** A readiness that has been marked ready and is then marked preparing
    /// reads *not ready*: the latch closes again. Before this aspect there was no call that could
    /// make this assertion true.
    func testMarkingPreparingAfterReadyClosesTheGateAgain() {
        let readiness = EngineReadiness()
        XCTAssertFalse(readiness.isReady, "a fresh readiness starts closed")

        readiness.markReady()
        XCTAssertTrue(readiness.isReady, "the prepared engine opens the gate")

        readiness.markPreparing()
        XCTAssertFalse(
            readiness.isReady,
            "a switch must be able to close the gate again — the engine that was prepared is not "
                + "the engine now selected")
    }

    /// **Phase 1, row 1 (idempotence).** Closing an already-closed readiness is a no-op, and a
    /// second `markReady` after a close re-opens it. The transition is a state assignment, not a
    /// counter: nothing about a switch should depend on how many times either was called.
    func testTheTwoTransitionsAreIdempotentAndReversible() {
        let readiness = EngineReadiness()

        readiness.markPreparing()
        XCTAssertFalse(readiness.isReady, "closing a closed gate leaves it closed")

        readiness.markReady()
        readiness.markReady()
        XCTAssertTrue(readiness.isReady, "opening twice is opening once")

        readiness.markPreparing()
        readiness.markPreparing()
        XCTAssertFalse(readiness.isReady, "closing twice is closing once")

        readiness.markReady()
        XCTAssertTrue(
            readiness.isReady,
            "the new engine's successful preparation re-opens the gate the switch closed")
    }

    // MARK: - Both gates, one readiness

    /// **Phase 1, row 2.** The two configurations' gates share **one** `EngineReadiness`
    /// (`DictationLoopRoot.init` builds both over the same instance), so a close reaches both.
    /// Driven through both gates rather than reasoned about, because a second readiness instance
    /// would leave the inactive mode's microphone openable after a switch and nothing else in the
    /// suite would notice.
    func testClosingTheReadinessRefusesBothConfigurationsMicrophones() {
        let readiness = EngineReadiness()
        let holdToTalkSource = RecordingAudioSource()
        let toggleSource = RecordingAudioSource()
        let holdToTalkGate = EngineReadinessGate(
            inner: holdToTalkSource, readiness: readiness)
        let toggleGate = EngineReadinessGate(inner: toggleSource, readiness: readiness)

        readiness.markReady()
        XCTAssertEqual(holdToTalkGate.beginCapture(), .opened)
        XCTAssertEqual(toggleGate.beginCapture(), .opened)
        _ = holdToTalkGate.endCapture()
        _ = toggleGate.endCapture()

        readiness.markPreparing()
        XCTAssertEqual(
            holdToTalkGate.beginCapture(), .unavailable,
            "the hold-to-talk microphone must refuse once the gate closes")
        XCTAssertEqual(
            toggleGate.beginCapture(), .unavailable,
            "the toggle microphone must refuse too — one readiness, both gates")
        XCTAssertEqual(
            holdToTalkSource.beginCount, 1,
            "a closed gate never reaches the microphone underneath it")
        XCTAssertEqual(toggleSource.beginCount, 1, "nor the toggle configuration's")
    }

    /// **Phase 1, row 4.** A closed gate refuses `beginCapture` with `.unavailable` and leaves the
    /// source untouched — the existing behaviour, pinned here because this aspect is where it could
    /// break. The refusal is what the machine turns into `.captureUnavailable` and the router turns
    /// into the honest `.modelUnavailable` notice.
    func testAClosedGateRefusesWithoutEverAskingTheMicrophone() {
        let readiness = EngineReadiness()
        let source = RecordingAudioSource()
        let gate = EngineReadinessGate(inner: source, readiness: readiness)

        XCTAssertEqual(gate.beginCapture(), .unavailable, "a fresh gate is closed")
        XCTAssertEqual(
            source.beginCount, 0,
            "the microphone is never asked while the engine is unprepared — the mic never opens")
        XCTAssertFalse(source.isOpen, "and it is certainly never left open")
    }

    // MARK: - The closed set of openers

    /// **Phase 1, row 3.** `markReady()` is the **only** thing in `EngineReadiness` that sets the
    /// flag true, and the only call site in `Sources/` is `DictationLoopRoot.markEnginePrepared()`,
    /// which the launch path reaches only after `prepareIfNeeded()` has succeeded.
    ///
    /// Read out of the shipped source, because the hazard is a path that does not exist yet. A
    /// behavioural test cannot fail for an opener nobody has written; this one fails the moment a
    /// second one is written, which forces whoever writes it to come here and argue for it.
    func testMarkReadyIsTheOnlyOpenerOfTheGate() throws {
        let source = try Self.bootstrapSource()

        let readinessBody = try XCTUnwrap(
            Self.declarationBody(named: "final class EngineReadiness", in: source),
            "EngineReadiness must still be declared in AppBootstrap.swift")

        let openingFunctions = Self.functionsOpeningTheGate(in: readinessBody)
        XCTAssertEqual(
            openingFunctions, ["markReady"],
            """
            the set of functions in EngineReadiness that open the gate changed. Opening it over an \
            engine whose prepare() has not succeeded routes a real recording into a pipeline that \
            cannot transcribe it — the one failure this gate exists to prevent. Closing it is \
            always safe; opening it is not. If a second opener is genuinely needed, say why here.
            """)

        let callSites = Self.linesCalling("markReady", in: source)
        XCTAssertEqual(
            callSites.count, 1,
            """
            markReady() must have exactly one call site in Sources/; found \(callSites.count): \
            \(callSites). The one permitted caller is markEnginePrepared(), which the launch path \
            reaches only after prepareIfNeeded() has succeeded.
            """)
        let markEnginePreparedBody = try XCTUnwrap(
            Self.declarationBody(named: "public func markEnginePrepared()", in: source),
            "markEnginePrepared() must still exist — it is the gate's one opener")
        XCTAssertTrue(
            markEnginePreparedBody.contains("markReady"),
            "markEnginePrepared() is the one permitted caller of markReady()")
    }

    // MARK: - The source scan

    /// `AppBootstrap.swift`, comments stripped — the only file that may name `EngineReadiness`.
    private static func bootstrapSource() throws -> String {
        let root = try PackageRootLocator.find(from: #filePath)
        let file = root.appendingPathComponent(
            "Sources/VoccaBootstrap/AppBootstrap.swift")
        return SwiftSourceScanner.stripComments(from: try String(contentsOf: file, encoding: .utf8))
    }

    /// The braced body of the declaration whose header text is `header`.
    private static func declarationBody(named header: String, in source: String) -> String? {
        guard let range = source.range(of: header) else { return nil }
        let characters = Array(source)
        let offset = source.distance(from: source.startIndex, to: range.upperBound)
        guard let brace = (offset..<characters.count).first(where: { characters[$0] == "{" })
        else { return nil }
        return SwiftSourceScanner.bracedBody(in: characters, openingBraceIndex: brace)?.body
    }

    /// Every `func` in `body` whose own body **opens** the gate.
    ///
    /// Two spellings are recognised, and both must be, because the type has already had one of
    /// each: the flag form (`isReady = true`) it shipped with, and the state form (`state = .ready`)
    /// it took when a third answer was needed for the surfaces. A scan that knew only the retired
    /// spelling would report an empty set and pass vacuously, which is how a lint quietly stops
    /// linting.
    private static func functionsOpeningTheGate(in body: String) -> Set<String> {
        var names: Set<String> = []
        let characters = Array(body)
        var index = 0
        while index < characters.count {
            guard
                let functionRange = String(characters[index...]).range(of: "func ")
            else { break }
            let start =
                index
                + String(characters[index...]).distance(
                    from: String(characters[index...]).startIndex, to: functionRange.upperBound)
            var name = ""
            var cursor = start
            while cursor < characters.count,
                characters[cursor].isLetter || characters[cursor].isNumber
                    || characters[cursor] == "_"
            {
                name.append(characters[cursor])
                cursor += 1
            }
            guard let brace = (cursor..<characters.count).first(where: { characters[$0] == "{" }),
                let function = SwiftSourceScanner.bracedBody(
                    in: characters, openingBraceIndex: brace)
            else { break }
            let compact = function.body.replacingOccurrences(of: " ", with: "")
            if compact.contains("isReady=true") || compact.contains("state=.ready") {
                names.insert(name)
            }
            index = function.closingBraceIndex + 1
        }
        return names
    }

    /// Every line in `source` that *calls* `name` — the declaration line excluded.
    private static func linesCalling(_ name: String, in source: String) -> [String] {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("\(name)()") && !$0.contains("func \(name)()") }
    }
}
