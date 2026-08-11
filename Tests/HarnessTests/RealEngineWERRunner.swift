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

/// A fixture whose tolerance is not a WER ceiling but a different rule
/// (`docs/planning/second-asr-engine/fixture-harness/spec.md:58-61`).
enum FixtureSpecialRule: Sendable, Equatable {
    /// The two-hundred-ms clip's rule (`docs/planning/local-asr/fixture-suite/spec.md:60`):
    /// **at most one substitution**. The golden is a single word, so the normalized WER is the
    /// substitution count itself (distance ÷ 1), and the bound reads WER ≤ 1.0 — carried
    /// identically for every engine, exactly as the fixture-suite spec's open question demands.
    case atMostOneSubstitution
}

/// Why a real-engine WER run failed, named by the violated clause.
///
/// Every per-fixture violation carries the run's full WER ledger, so a real-run failure hands the
/// re-baseline decision (PRD M6) every fixture's number in one error — the run never silently
/// relaxes a tolerance and never fails without the data to re-baseline it.
enum RealEngineWERRunnerError: Error, Equatable, CustomStringConvertible {
    /// The evaluation returned a different number of results than fixtures.
    case resultCountMismatch(expected: Int, actual: Int)
    /// The table names neither the fixture nor the `"clean"` fallback.
    case missingTolerance(fixture: String)
    /// A transcript was attributed to an engine other than the one the run is for.
    case attributionMismatch(
        fixture: String, expected: EngineIdentity, actual: EngineIdentity, ledger: [String: Double])
    /// The transcript's WER is above the fixture's ceiling from the table.
    case toleranceExceeded(
        fixture: String, wer: Double, tolerance: Double, transcript: String, ledger: [String: Double])
    /// The transcript is more than one substitution from the single-word golden.
    case substitutionRuleViolated(
        fixture: String, wer: Double, transcript: String, ledger: [String: Double])

    var description: String {
        switch self {
        case .resultCountMismatch(let expected, let actual):
            return "the run produced \(actual) results for \(expected) fixtures"
        case .missingTolerance(let fixture):
            return "no tolerance for \(fixture) and no \"clean\" fallback in the table"
        case .attributionMismatch(let fixture, let expected, let actual, let ledger):
            return "\(fixture): transcript attributed to \(actual.id), expected \(expected.id) — "
                + "ledger: \(ledger)"
        case .toleranceExceeded(let fixture, let wer, let tolerance, let transcript, let ledger):
            return "\(fixture): WER \(wer) exceeds the tolerance \(tolerance) — "
                + "transcript: \"\(transcript)\" — ledger: \(ledger)"
        case .substitutionRuleViolated(let fixture, let wer, let transcript, let ledger):
            return "\(fixture): WER \(wer) violates the at-most-one-substitution rule — "
                + "transcript: \"\(transcript)\" — ledger: \(ledger)"
        }
    }
}

/// One test body, parameterized over engine, tolerance table and special rules — the C2 real-run
/// half extracted from `ParakeetEngineWERTests` so the same six-fixture suite runs against every
/// real engine (`plan_20260810.md` Phase 1; the fixture-harness spec's acceptance criterion 1).
///
/// The caller **prepares the engine** — each engine owns its prepare policy — and supplies:
/// - `expectedIdentity`: every transcript must be attributed to it (invariant I1);
/// - `toleranceTable`: per-fixture WER ceilings, `"clean"` as the fallback;
/// - `specialRules`: fixtures whose bound is a rule, not a WER ceiling — the 200 ms
///   substitution rule applies identically to both engines (`spec.md:58-61`);
/// - `fixturesDirectory`: where `ASRFixtureSuite` looks for `*.wav`/`.txt` pairs
///   (defaults to the checked-in `Tests/Fixtures/`).
///
/// Fixtures are loaded and evaluated through ``ASRFixtureSuite``; every violation throws
/// ``RealEngineWERRunnerError``. A directory with nothing to measure fails loudly through the
/// suite's own loader — a green zero-result run is structurally impossible.
enum RealEngineWERRunner {

    static func run(
        engine: any ASREngine,
        expectedIdentity: EngineIdentity,
        toleranceTable: [String: Double],
        specialRules: [String: FixtureSpecialRule] = [:],
        fixturesDirectory: URL? = nil
    ) async throws {
        let fixtures = try ASRFixtureSuite.loadFixtures(from: fixturesDirectory)
        let results = try await ASRFixtureSuite.evaluate(engine, fixtures: fixtures)
        guard results.count == fixtures.count else {
            throw RealEngineWERRunnerError.resultCountMismatch(
                expected: fixtures.count, actual: results.count)
        }
        let ledger = Dictionary(uniqueKeysWithValues: results.map { ($0.name, $0.wer) })
        for result in results {
            guard result.engine == expectedIdentity else {
                throw RealEngineWERRunnerError.attributionMismatch(
                    fixture: result.name, expected: expectedIdentity, actual: result.engine,
                    ledger: ledger)
            }
            if let rule = specialRules[result.name] {
                switch rule {
                case .atMostOneSubstitution:
                    guard result.wer <= 1.0 else {
                        throw RealEngineWERRunnerError.substitutionRuleViolated(
                            fixture: result.name, wer: result.wer, transcript: result.transcript,
                            ledger: ledger)
                    }
                }
            } else {
                guard let tolerance = toleranceTable[result.name] ?? toleranceTable["clean"] else {
                    throw RealEngineWERRunnerError.missingTolerance(fixture: result.name)
                }
                guard result.wer <= tolerance else {
                    throw RealEngineWERRunnerError.toleranceExceeded(
                        fixture: result.name, wer: result.wer, tolerance: tolerance,
                        transcript: result.transcript, ledger: ledger)
                }
            }
        }
    }
}
