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
import VoccaASR
import VoccaCore
import XCTest

/// The C3 acceptance's real-number half for the second engine: the same six-fixture suite run
/// against the actual whisper.cpp engine, env-gated exactly like `ParakeetEngineWERTests` — the
/// model cannot reach a hosted runner, and the manifest is committed by the founder's
/// provisioning run (`Scripts/provision-asr-fixtures.sh --engine whisper-large-v3-turbo`).
///
/// Without `VOCCA_MODEL_DIR` the test **skips visibly**, and the skip path never touches the
/// manifest — which may not exist yet on a fresh checkout; with it, it is the gate: the six
/// fixtures within the provisional tolerances, offline (the transport is a stub base URL — the
/// store is a no-op when the model is present and verified), and every transcript attributed to
/// the whisper identity.
///
/// The tolerances below are **provisional by decision**, seeded from Parakeet's provisional
/// numbers — the TTS stand-ins are unnaturally clean, so these are a starting point, not a
/// claim. `tolerances_20260810.md` records the re-baseline procedure: the founder's first real
/// run measures the WER, the margin is added, the founder signs, and the F2 recordings replace
/// these numbers — in exactly this file (and Parakeet's).
final class WhisperCppEngineWERTests: XCTestCase {

    /// The provisional tolerances, seeded from Parakeet's provisional numbers: per-fixture WER
    /// ceilings, plus the 200 ms clip's single-substitution rule — which applies identically to
    /// both engines. Provisional pending the founder's first real run; the re-baseline procedure
    /// is `docs/planning/second-asr-engine/fixture-harness/tolerances_20260810.md`.
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
                "set VOCCA_MODEL_DIR to a store-shaped whisper version directory — see "
                    + "Scripts/provision-asr-fixtures.sh --engine whisper-large-v3-turbo")
        }
        let modelDirectory = URL(fileURLWithPath: modelDir)

        // The shipped manifest: engineID/version + the GGUF's digests the store verifies.
        // Committed by the founder's provisioning run — the skip path above returns before
        // this line, so a fresh checkout without the manifest still runs green-skipped.
        let manifestURL = try PackageRootLocator.find(from: #filePath)
            .appendingPathComponent("Sources/VoccaASR/Models/Manifests/whisper-large-v3-turbo.json")
        let manifest = try ModelManifest.load(from: Data(contentsOf: manifestURL))

        // The store rooted at the model tree's root (the version directory's grandparent:
        // `<root>/<engineID>/<version>/`); the transport is never reached when the model is
        // present and verified (downloadIfMissing is a no-op), so its base URL is a stub.
        let store = ModelStore(
            rootURL: modelDirectory
                .deletingLastPathComponent()
                .deletingLastPathComponent())
        let engine = WhisperCppEngine(
            store: store,
            manifest: manifest,
            transport: DefaultModelTransport(
                baseURL: URL(string: "https://unused.invalid")!),
            clock: ContinuousMonotonicClock())

        try await engine.prepare()

        try await RealEngineWERRunner.run(
            engine: engine,
            expectedIdentity: WhisperCppEngineIdentity.whisper,
            toleranceTable: provisionalTolerances,
            specialRules: ["two-hundred-ms": .atMostOneSubstitution])
    }
}
