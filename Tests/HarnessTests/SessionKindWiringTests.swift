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

import XCTest

/// The one place a composition becomes a ``SessionKind`` — pinned, because nothing else can reach
/// it.
///
/// `AppBootstrap.configure` derives the kind from `injectorComposition` once and threads it to the
/// pipeline and the router. Every other test in the tree that constructs a pipeline *states* its
/// kind, because a headless pipeline has no composition root above it — which means the mapping
/// itself is asserted by nothing. Swap the two arms and onboarding's sessions record as real
/// work: the P0 loss figure (`ROADMAP.md:95`, fixed at exactly zero) would count a refused TRY IT
/// against daily use, an onboarding-only day would extend the streak `ROADMAP.md:102` measures,
/// and the whole suite would stay green.
///
/// `configure` is `@MainActor`, builds an audio graph and an event tap, and is executed by nothing
/// in CI — so this is a source scan, the `SpeechTabWiringTests` shape, aimed at the smallest fact
/// that matters: which kind each arm assigns.
final class SessionKindWiringTests: XCTestCase {

    /// The `switch injectorComposition` block inside `configure`, comments stripped and whitespace
    /// collapsed — so a mention in prose is never mistaken for the wiring, and reformatting the
    /// file does not fail the pin.
    private static func sessionKindSwitchBody() throws -> String {
        let root = try PackageRootLocator.find(from: #filePath)
        let file = root.appendingPathComponent("Sources/VoccaBootstrap/AppBootstrap.swift")
        let source = SwiftSourceScanner.stripComments(
            from: try String(contentsOf: file, encoding: .utf8))
        let header = "let sessionKind: SessionKind"
        guard let start = source.range(of: header) else {
            XCTFail(
                """
                `configure` no longer declares `let sessionKind: SessionKind`. That declaration is \
                where a composition becomes the kind its records carry; if it moved, this pin has \
                to move with it rather than be deleted.
                """)
            return ""
        }
        var depth = 0
        var body = ""
        for character in source[start.upperBound...] {
            if character == "{" { depth += 1 }
            if depth > 0 { body.append(character) }
            if character == "}" {
                depth -= 1
                if depth == 0 { break }
            }
        }
        return body.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// Each arm assigns its own kind: the ladder records real dictation, the onboarding
    /// composition records a setup demo.
    ///
    /// Asserted as ordered occurrence rather than exact text, so the pin survives reformatting but
    /// still fails if the two assignments are exchanged.
    func testEachInjectorCompositionAssignsItsOwnSessionKind() throws {
        let body = try Self.sessionKindSwitchBody()
        guard !body.isEmpty else { return }

        guard let ladder = body.range(of: "case .ladder:"),
            let onboarding = body.range(of: "case .onboarding:")
        else {
            XCTFail(
                """
                The composition switch no longer names both arms. It is deliberately total, with \
                no `default:`, so that a third composition has to say which kind of session it \
                records as rather than inheriting one from a branch nobody re-read: \
                \(body)
                """)
            return
        }

        let ladderArm = body[ladder.upperBound..<onboarding.lowerBound]
        let onboardingArm = body[onboarding.upperBound...]

        XCTAssertTrue(
            ladderArm.contains("sessionKind = .dictation"),
            """
            The ladder composition no longer records `.dictation`. The ladder is the real \
            dictation loop — the daily use `ROADMAP.md:102`'s gate is about — and recording it as \
            anything else empties the streak of the sessions that should build it: \(ladderArm)
            """)
        XCTAssertTrue(
            onboardingArm.contains("sessionKind = .onboarding"),
            """
            The onboarding composition no longer records `.onboarding`. Onboarding shares the \
            production ledger and its injector never holds, so a refused TRY IT finalizes `.lost` \
            — recorded as `.dictation` it becomes a lost transcript counted against real work, in \
            the one metric `ROADMAP.md:95` fixes at exactly zero: \(onboardingArm)
            """)
    }

    /// The scan is not vacuous: it must reject the swap it exists to catch.
    ///
    /// Run against a body with the two assignments exchanged, the same containment checks that
    /// pass above have to fail — otherwise the pin would hold over a tree where onboarding records
    /// as real work, which is the whole failure it is here to prevent.
    func testTheWiringScanRejectsAnExchangedPairOfArms() {
        let swapped = "{ case .ladder: sessionKind = .onboarding case .onboarding: "
            + "sessionKind = .dictation }"

        guard let ladder = swapped.range(of: "case .ladder:"),
            let onboarding = swapped.range(of: "case .onboarding:")
        else {
            XCTFail("the planted body names both arms — the split is what is under test")
            return
        }
        let ladderArm = swapped[ladder.upperBound..<onboarding.lowerBound]
        let onboardingArm = swapped[onboarding.upperBound...]

        XCTAssertFalse(
            ladderArm.contains("sessionKind = .dictation"),
            "the scan would pass a ladder arm recording onboarding — it splits the arms wrongly")
        XCTAssertFalse(
            onboardingArm.contains("sessionKind = .onboarding"),
            "the scan would pass an onboarding arm recording dictation — it reads past its arm")
    }
}
