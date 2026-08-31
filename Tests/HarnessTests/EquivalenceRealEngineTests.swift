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

import FluidAudio
import Foundation
import VoccaASR
import VoccaCore
import XCTest

/// The equivalence measurement's real-number half: ``EquivalenceRealEngineRunner`` over the real
/// Parakeet engine and the full discovered fixture suite — env-gated exactly like
/// ``LatencyBenchmarkRealEngineTests`` (the model cannot reach a hosted runner, so without
/// `VOCCA_LATENCY_BENCH` this test **skips visibly**, and CI runs the skip path).
///
/// This is a **thin shell** over the runner: the engine-specific half (the two-var gate, the
/// manifest, the store, the offline-flag assertion) lives here, and the measurement half lives
/// in the runner — the ``RealEngineWERRunner`` split.
///
/// ## Records, never gates
///
/// This test asserts the record's **shape only** — one row per fixture, every row carrying its
/// wer/exact/shape/verdict, no unreadable suppression, the streaming guard's VOID-with-reason
/// when the adapter has not landed — and **no tolerance value is ever asserted**. A blown
/// tolerance records a NO-GO row and is a successful unit outcome: the latency claim is
/// dropped, the feature ships. The founder re-baselines the provisional table via the
/// `tolerances_20260831.md` procedure, never by this test failing.
final class EquivalenceRealEngineTests: XCTestCase {

    /// **The first streamed-vs-batch equivalence run** (SMOKE steps 125-126): every discovered
    /// fixture driven twice — batch `transcribe` and streamed (1 s chunks → final) — compared,
    /// printed with the suppression state beside every row, and recorded, never gated.
    func testTheRealEngineEquivalenceRunRecordsTheVerdictShape() async throws {
        guard ProcessInfo.processInfo.environment["VOCCA_LATENCY_BENCH"] != nil else {
            throw XCTSkip(
                "set VOCCA_LATENCY_BENCH=1 to run the real-engine equivalence benchmark — the "
                    + "model cannot reach a hosted runner, so CI runs the skip path")
        }
        guard
            let modelDir = ProcessInfo.processInfo.environment["VOCCA_MODEL_DIR"]
        else {
            throw XCTSkip(
                "set VOCCA_MODEL_DIR to a store-shaped version directory — see "
                    + "Scripts/provision-asr-fixtures.sh")
        }
        let modelDirectory = URL(fileURLWithPath: modelDir)

        // The shipped manifest + the store rooted at the model tree's root — the WER construction,
        // verbatim (`ParakeetEngineWERTests.swift:62-78`): the transport is never reached when the
        // model is present and verified, so its base URL is a stub.
        let manifestURL = try PackageRootLocator.find(from: #filePath)
            .appendingPathComponent("Sources/VoccaASR/Models/Manifests/parakeet-tdt-0.6b-v3.json")
        let manifest = try ModelManifest.load(from: Data(contentsOf: manifestURL))
        let store = ModelStore(
            rootURL: modelDirectory
                .deletingLastPathComponent()
                .deletingLastPathComponent())
        let engine = ParakeetEngine(
            store: store,
            manifest: manifest,
            transport: DefaultModelTransport(
                baseURL: URL(string: "https://unused.invalid")!),
            clock: ContinuousMonotonicClock(),
            timing: EngineTiming())
        try await engine.prepare()

        // The structural offline half of the acceptance: the SDK's own network path is disabled
        // by the engine's construction — asserted, not assumed (the WER tests' assertion).
        XCTAssertTrue(
            ModelHub.offlineMode,
            "the engine must set the SDK's offline flag at construction")

        let fixtures = try ASRFixtureSuite.loadFixtures()
        let result = try await EquivalenceRealEngineRunner.run(
            engine: engine,
            fixtures: fixtures,
            toleranceTable: ProvisionalEquivalenceTolerances.table,
            suppression: darwinSuppressionState,
            clock: ContinuousMonotonicClock())

        let rows = result.fixtures
        XCTAssertEqual(
            rows.count, fixtures.count,
            "one recorded row per driven fixture")
        XCTAssertEqual(
            Set(rows.map(\.row.fixtureName)), Set(fixtures.map(\.name)),
            "every discovered fixture has a recorded row — a suite that cannot measure never "
                + "reads green")
        XCTAssertTrue(
            rows.allSatisfy { !$0.row.batchText.isEmpty || !$0.row.streamedFinalText.isEmpty },
            "every row carries its transcripts — the founder must be able to eyeball the diff")

        // The streaming guard's verdict is VOID-with-reason when the adapter has not landed —
        // batch-vs-batch would prove nothing and must not be able to read as PASS. With the
        // adapter landed, the verdicts are whatever the run records — never asserted.
        if !engine.supportsStreaming {
            XCTAssertTrue(
                rows.allSatisfy {
                    $0.verdict == .void(
                        reason: "engine does not stream — batch-vs-batch comparison proves nothing")
                },
                "a non-streaming engine records VOID with the named reason on every row")
        }

        XCTAssertFalse(
            rows.contains {
                if case .unreadable = $0.suppression { return true } else { return false }
            },
            "no row may carry an unreadable suppression state as an answer — an unreadable state "
                + "is a void run, not a row")

        // The key-up-cost row's shape (never its values): the sixty-second fixture records what
        // the streamed final actually costs at key-up vs the full batch — the "only the tail is
        // unprocessed" premise, measured not assumed. A run whose engine does not stream has no
        // durations (the VOID rows), so the shape assertion holds only on the streaming path.
        if engine.supportsStreaming {
            let sixtySecond = try XCTUnwrap(
                rows.first { $0.row.fixtureName == "sixty-second" },
                "the sixty-second fixture is part of the discovered suite")
            XCTAssertNotNil(
                sixtySecond.batchElapsed,
                "the sixty-second row records the full-batch cost — the key-up row's comparison "
                    + "half")
            XCTAssertNotNil(
                sixtySecond.keyUpElapsed,
                "the sixty-second row records what the streamed final actually costs at key-up")
            XCTAssertNotNil(
                sixtySecond.streamedElapsed,
                "the sixty-second row records first-chunk-to-final — recorded, nothing claimed "
                    + "from it")
        }

        print(
            "verdict: \(result.verdict) — RECORDED, never gated: a FAIL here blocks claiming "
                + "the latency win, never shipping the feed")
    }
}