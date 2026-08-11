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

/// The C2 acceptance's real-number half: the fixture suite against the actual Parakeet engine —
/// env-gated, because the model cannot reach a hosted runner and the F1 verdict is pending.
///
/// This is a **thin shell** over ``RealEngineWERRunner``: the engine-specific half (the env gate,
/// the manifest, the store, the offline-flag assertion) lives here, and the measurement half — one
/// body, parameterized over engine + tolerance table + special rules — lives in the runner, so the
/// same six-fixture suite runs against whisper.cpp too (`plan_20260810.md` Phase 1).
///
/// Without `VOCCA_MODEL_DIR` (a store-shaped version directory — see
/// `Scripts/provision-asr-fixtures.sh`), the test **skips visibly**; with it, it is the gate:
/// the five fixtures within the provisional tolerances, the offline flag structural, and every
/// transcript attributed to the Parakeet identity.
///
/// The tolerances below are **provisional by decision** (the founding choice — set from the
/// founder's first real run, never guessed). They live in exactly one place: here — only
/// `tolerances_20260810.md`'s re-baseline (measured + margin, founder-signed, F2 recordings)
/// moves them.
final class ParakeetEngineWERTests: XCTestCase {

    /// The provisional tolerances: per-fixture WER ceilings, plus the 200 ms clip's
    /// single-substitution rule. These numbers move — only here — after the founder's first
    /// real run.
    private let provisionalTolerances: [String: Double] = [
        "clean": 0.10,
        "spike-clip": 0.10,
        "accented": 0.12,
        "noisy": 0.20,
        "sixty-second": 0.10,
        "two-hundred-ms": 1.0,
    ]

    func testTheRealEngineMeetsTheProvisionalTolerancesOffline() async throws {
        guard
            let modelDir = ProcessInfo.processInfo.environment["VOCCA_MODEL_DIR"]
        else {
            throw XCTSkip(
                "set VOCCA_MODEL_DIR to a store-shaped version directory — see Scripts/provision-asr-fixtures.sh")
        }
        let modelDirectory = URL(fileURLWithPath: modelDir)

        // The shipped manifest: engineID/version/sdkDirectory + the digests the store verifies.
        let manifestURL = try PackageRootLocator.find(from: #filePath)
            .appendingPathComponent("Sources/VoccaASR/Models/Manifests/parakeet-tdt-0.6b-v3.json")
        let manifest = try ModelManifest.load(from: Data(contentsOf: manifestURL))

        // The store rooted at the model tree's root (the version directory's grandparent:
        // `<root>/<engineID>/<version>/`); the transport is never reached when the model is
        // present and verified (downloadIfMissing is a no-op), so its base URL is a stub.
        let store = ModelStore(
            rootURL: modelDirectory
                .deletingLastPathComponent()
                .deletingLastPathComponent())
        let engine = ParakeetEngine(
            store: store,
            manifest: manifest,
            transport: DefaultModelTransport(
                baseURL: URL(string: "https://unused.invalid")!),
            clock: ContinuousMonotonicClock())

        try await engine.prepare()

        // The structural offline half of the acceptance: the SDK's own network path is disabled
        // by the engine's construction — asserted, not assumed. Engine-specific, so it stays
        // here rather than in the runner.
        XCTAssertTrue(
            ModelHub.offlineMode,
            "the engine must set the SDK's offline flag at construction")

        try await RealEngineWERRunner.run(
            engine: engine,
            expectedIdentity: ParakeetEngineIdentity.parakeet,
            toleranceTable: provisionalTolerances,
            specialRules: ["two-hundred-ms": .atMostOneSubstitution])
    }
}
