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
import VoccaUI
import XCTest

/// The session-start read of the engine selection (`engine-picker` Phase 4): a session resolves
/// the engine it will run **once, at start**, from the selection value that was current then.
///
/// Two promises meet here:
///
/// - **No restart needed** (`CAPABILITY_ROADMAP.md:78`): a session begun *after* a selection
///   change reads the *new* selection.
///
///   This comment used to end "so nothing about it is cached at launch", which was true of the pure
///   function below and false of the app around it. It was: `AppBootstrap.configure` hardcoded
///   `EngineSelection.defaultSelection` at five sites, and `DictationEngineResolver` fixed its
///   selection at `init` with no reset — so changing the engine and pressing the hotkey ran the
///   engine the app had launched with, for as long as the app kept running. The pure resolution had
///   nothing cached; the wiring cached everything.
///
///   What makes it true is not this function but the `engine-resolution` aspect: the root reads the
///   persisted selection at every site (`EngineSelectionWiringTests`), and a change **replaces the
///   resolver** and eagerly prepares the new engine (`EngineSwitchTests`) — because resolve-once is
///   a promise worth keeping, so a switch is a new resolver rather than a mutated one. This file
///   pins the pure half; those two pin the half that had been claiming it.
/// - **No engine swap under a running session** (the never-auto-switch rule, in its
///   consumption form): resolution returns an ``EngineIdentity`` value — a snapshot. A
///   mid-session selection change moves the *picker's* state, not the identity a running
///   session already holds; the resolver's output is immune by construction, and the reducer's
///   never-auto-switch rule keeps the same promise on the state side.
///
/// The resolver itself (`EngineSessionStart.resolve(selection:)`) shipped with the Phase 3 view
/// file — it lives in `VoccaUI` next to the view it serves; this table is the pin that makes it
/// a contract.
final class EngineSelectionConsumptionTests: XCTestCase {

    /// Row (a): a fresh install's first session runs the shipped default — Parakeet v3, at its
    /// own tier, resolving to the Parakeet engine identity.
    func testResolvingTheDefaultSelectionYieldsTheParakeetIdentity() {
        let identity = EngineSessionStart.resolve(selection: .defaultSelection)
        XCTAssertEqual(identity, EngineCandidate.parakeetV3.identity)
        XCTAssertEqual(identity.id, "parakeet-tdt-0.6b-v3")
        XCTAssertTrue(identity.isLocal, "the seeded engines are local — no egress badge")
    }

    /// Row (b): selecting Whisper turbo resolves the whisper engine — the id the transcripts are
    /// attributed to, and the id the model store keys its directory by.
    func testSelectingWhisperTurboResolvesTheWhisperIdentity() {
        let identity = EngineSessionStart.resolve(
            selection: EngineSelection(tier: .whisperTurbo))
        XCTAssertEqual(identity, EngineCandidate.whisperTurbo.identity)
        XCTAssertEqual(identity.id, "whisper-large-v3-turbo")
        XCTAssertEqual(identity.displayName, "Whisper turbo")
    }

    /// Row (c): the tier is a **model choice, not a different engine** — both Whisper tiers
    /// resolve to the same identity, and the closed-set mirror holds for every tier that exists:
    /// each resolves to exactly the engine it belongs to.
    func testTheQ5TierResolvesToTheSameEngineIdentity() {
        let full = EngineSessionStart.resolve(selection: EngineSelection(tier: .whisperTurbo))
        let q5 = EngineSessionStart.resolve(selection: EngineSelection(tier: .whisperTurboQ5))
        XCTAssertEqual(q5, EngineCandidate.whisperTurbo.identity)
        XCTAssertEqual(q5, full,
            "turbo and q5_0 are two model choices of one engine — the identity must not change")

        for tier in EngineTier.allCases {
            XCTAssertEqual(
                EngineSessionStart.resolve(selection: EngineSelection(tier: tier)),
                tier.engine.identity,
                "\(tier) must resolve to the engine it belongs to")
        }
    }

    /// Row (d): the resolution is a **snapshot**. A session resolves once at start and keeps the
    /// identity; a mid-session selection change moves the picker's state and cannot reach the
    /// running session's identity. And the companion promise: a session begun *after* the change
    /// reads the new selection — switching engines needs no restart.
    func testAMidSessionSelectionChangeDoesNotAffectTheAlreadyResolvedIdentity() {
        let atStart = EngineSessionStart.resolve(selection: .defaultSelection)

        // Mid-session, the user switches to Whisper q5_0 — the picker's selection moves...
        let midSession = EngineSelection(tier: .whisperTurboQ5)
        XCTAssertEqual(midSession.engine, .whisperTurbo,
            "the changed selection really did move to Whisper")

        // ...but the running session keeps exactly the identity it resolved at start.
        XCTAssertEqual(atStart, EngineCandidate.parakeetV3.identity,
            "the already-resolved identity is a snapshot — a later change cannot swap the engine "
                + "under a running session")

        // The *next* session reads the *new* selection.
        XCTAssertEqual(
            EngineSessionStart.resolve(selection: midSession),
            EngineCandidate.whisperTurbo.identity,
            "a session begun after the change must use the new engine — no restart needed")
    }
}
