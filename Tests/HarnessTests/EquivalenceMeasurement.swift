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

// MARK: - The comparison

/// The shape of the token-level difference between the batch transcript and the streamed final —
/// the answer to *how* they differ, because the roadmap's speculative premise is "only the tail
/// is unprocessed": a shared leading prefix that then diverges is that premise's prediction,
/// while a wholesale drift contradicts it. The shared-token count is carried so the printed
/// shape shows the actual boundary, never a guessed one.
enum TokenDiffShape: Equatable {
    /// Both sides tokenize to the same sequence (both-empty included — the sub-minimum row).
    case identical
    /// At least one shared leading token, then a divergence.
    case prefixThenDiverge(commonTokens: Int)
    /// The very first tokens differ — nothing of the batch's beginning survives.
    case wholesaleDrift
}

/// The comparison and the verdict decision — pure code over scripted strings (Phase (a) of the
/// equivalence-measurement plan). The comparison is the shipped `WER.compute` (reference =
/// batch, hypothesis = streamed final) plus the token-diff shape; the verdict is a decision
/// over (row, tolerance, preconditions) where **any** unmet precondition voids the row — SMOKE
/// rule 1: void, not fail.
enum StreamedVsBatchComparison {

    /// One fixture's comparison row: the WER of the streamed final against the batch, whether
    /// the raw texts are exactly equal, and the token-diff shape.
    struct EquivalenceRow: Equatable {
        let fixtureName: String
        let batchText: String
        let streamedFinalText: String
        let wer: Double
        let exactEqual: Bool
        let shape: TokenDiffShape
    }

    /// Compares one fixture's two sides into the row the verdict and the printed table render.
    static func compare(
        fixtureName: String, batchText: String, streamedFinalText: String
    ) -> EquivalenceRow {
        EquivalenceRow(
            fixtureName: fixtureName,
            batchText: batchText,
            streamedFinalText: streamedFinalText,
            wer: WER.compute(reference: batchText, hypothesis: streamedFinalText),
            exactEqual: batchText == streamedFinalText,
            shape: tokenDiffShape(batch: batchText, streamed: streamedFinalText))
    }

    /// Decides one row: over the tolerance → `.fail`; within → `.pass`; **any** unmet
    /// precondition → `.void(reason:)` — the SMOKE rule 1 shape, so a throttled or
    /// batch-vs-batch number can never read as a pass.
    static func decide(
        row: EquivalenceRow, tolerance: Double, preconditions: EquivalencePreconditions
    ) -> EquivalenceVerdict {
        guard preconditions.suppressionReadable else {
            return .void(reason: "suppression state unreadable — treat every number below as void")
        }
        guard preconditions.engineStreams else {
            return .void(reason: "engine does not stream — batch-vs-batch comparison proves nothing")
        }
        guard preconditions.batchPresent else {
            return .void(reason: "missing side: batch")
        }
        guard preconditions.streamedFinalPresent else {
            return .void(reason: "missing side: streamed final")
        }
        return row.wer <= tolerance ? .pass : .fail
    }

    /// The mechanical shape rule: tokenize both sides with the same normalization as `WER`
    /// (letters + apostrophes, lowercased — the split is reimplemented here, never reached into),
    /// identical sequences → `.identical`; ≥ 1 shared leading token then a divergence →
    /// `.prefixThenDiverge(count:)`; first tokens differing → `.wholesaleDrift`.
    static func tokenDiffShape(batch: String, streamed: String) -> TokenDiffShape {
        let batchTokens = tokenize(batch)
        let streamedTokens = tokenize(streamed)
        if batchTokens == streamedTokens { return .identical }
        var common = 0
        while common < batchTokens.count, common < streamedTokens.count,
            batchTokens[common] == streamedTokens[common]
        {
            common += 1
        }
        if common >= 1 { return .prefixThenDiverge(commonTokens: common) }
        return .wholesaleDrift
    }

    /// Lowercased, split on non-letter/non-apostrophe characters, empty tokens dropped — the
    /// `WER` normalization, reimplemented locally per the plan (never reaching into the
    /// scorer's private helper).
    private static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && $0 != "'" }
            .map(String.init)
    }
}

// MARK: - The preconditions

/// The preconditions a verdict may be judged against — each unmet one voids the row with a
/// named reason rather than producing a pass/fail over numbers the run did not earn.
struct EquivalencePreconditions: Equatable {
    /// The darwin suppression state was readable at the row's recording.
    var suppressionReadable: Bool = true
    /// The engine under test streams — a non-streaming engine compares batch against batch,
    /// which proves nothing.
    var engineStreams: Bool = true
    /// The batch side exists.
    var batchPresent: Bool = true
    /// The streamed side exists — exactly one final was yielded.
    var streamedFinalPresent: Bool = true
}

// MARK: - The verdicts

/// One fixture's verdict: pass, fail, or void with the named reason.
enum EquivalenceVerdict: Equatable {
    case pass
    case fail
    case void(reason: String)
}

/// The go/no-go row over all fixtures: **GO** (every row `.pass`), **NO-GO** (any row `.fail`,
/// naming the fixtures), **VOID** (no fails, any `.void`, naming the reasons). Pure and
/// table-tested — this is the verdict the benchmark prints and the SMOKE record enters, never
/// a gate.
enum EquivalenceRunVerdict: Equatable {
    case go
    case noGo(fixtures: [String])
    case void(reasons: [String])

    static func decide(records: [EquivalenceFixtureRecord]) -> EquivalenceRunVerdict {
        let fails = records.filter { $0.verdict == .fail }
        if !fails.isEmpty {
            return .noGo(fixtures: fails.map(\.row.fixtureName))
        }
        let voidReasons = records.compactMap { record -> String? in
            if case .void(let reason) = record.verdict { return reason }
            return nil
        }
        if !voidReasons.isEmpty {
            return .void(reasons: voidReasons)
        }
        return .go
    }
}

// MARK: - The one-file tables and targets

/// **The one file the provisional equivalence tolerance table lives in.** Placeholder-seeded by
/// decision (the whisper "seeded, not measured" precedent — equivalence had no table to seed
/// from, so all six discovered fixtures sit at 0.05): PROVISIONAL-BY-DECISION until the
/// founder's first run re-baselines it via the `tolerances_20260825.md:42-57` procedure
/// (measure → margin → founder-signed → land in exactly this file → a failing run re-baselines,
/// never silently relaxes). The first run prints raw numbers beside the provisional verdict —
/// the re-baseline decision is never made on the provisional verdict alone.
enum ProvisionalEquivalenceTolerances {
    static let table: [String: Double] = [
        "clean": 0.05,
        "spike-clip": 0.05,
        "accented": 0.05,
        "noisy": 0.05,
        "sixty-second": 0.05,
        "two-hundred-ms": 0.05,
    ]

    /// The `table[name] ?? table["clean"]` fallback shape of the WER runner — a new fixture
    /// inherits the clean tolerance until the table names it; a table without even the fallback
    /// answers nil, which the runner turns into a loud failure, never a free pass.
    static func tolerance(for fixture: String, in table: [String: Double]) -> Double? {
        table[fixture] ?? table["clean"]
    }
}

/// The equivalence run's measurement targets, single-sourced (plan resolution 4).
enum EquivalenceMeasurementTargets {
    /// The streamed run's chunk size: 1 s at the interchange rate — 16 000 samples. Single-
    /// sourced here; if the sibling adapter refuses it (an SDK minimum), it is raised **in
    /// exactly this file** and the raise is said in the commit message, never silent.
    static let streamChunkSamples = 16_000
}

// MARK: - The run record and the rendering

/// One fixture's full record: the comparison row, its verdict, the three measured durations
/// (batch, key-up, streamed — Phase (d)'s accounting, nil until the runner measures them), the
/// partial count observed on the streamed side, and the darwin suppression state read beside
/// the row (SMOKE rule 1: a throttled number is recorded as throttled, never clean).
struct EquivalenceFixtureRecord {
    let row: StreamedVsBatchComparison.EquivalenceRow
    let verdict: EquivalenceVerdict
    /// Wall time around the batch `transcribe`.
    let batchElapsed: Duration?
    /// Wall time from the last chunk's delivery to the final transcript — the `finish()` decode,
    /// the honest "cost at key-up".
    let keyUpElapsed: Duration?
    /// First chunk to final — recorded, nothing claimed from it.
    let streamedElapsed: Duration?
    /// How many non-final transcripts the streamed side yielded before the final.
    let partialsObserved: Int
    let suppression: DarwinSuppression
}

/// The run's record: one fixture record per driven fixture, plus the summary verdict.
struct EquivalenceRunResult {
    let fixtures: [EquivalenceFixtureRecord]
    let verdict: EquivalenceRunVerdict
}

/// The verdict table's rendering: one row per fixture with the suppression state beside it,
/// and the constant sentence the print output must carry — whisper needs no equivalence run.
enum EquivalenceRowRenderer {

    /// The named sentence (spec M6): whisper's final equals batch by construction — repeated
    /// `whisper_full` on the growing buffer, the final the last full decode — so the harness is
    /// Parakeet-only and the output says why, pinned by test.
    static let whisperExclusionNote =
        "whisper.cpp needs no equivalence run: its final equals batch by construction "
        + "(repeated whisper_full on the growing buffer; the final is the last full decode)."

    /// One table row: fixture, WER, exact, shape, key-up cost, suppression — the six columns.
    static func renderRow(_ record: EquivalenceFixtureRecord) -> String {
        let fixture = record.row.fixtureName.padding(toLength: 16, withPad: " ", startingAt: 0)
        let wer = String(format: "%.3f", record.row.wer)
            .padding(toLength: 7, withPad: " ", startingAt: 0)
        let exact = (record.row.exactEqual ? "yes" : "no")
            .padding(toLength: 6, withPad: " ", startingAt: 0)
        let shape = shapeText(record.row.shape)
            .padding(toLength: 18, withPad: " ", startingAt: 0)
        let keyUp = (record.keyUpElapsed.map { "\(milliseconds($0)) ms" } ?? "n/a")
            .padding(toLength: 7, withPad: " ", startingAt: 0)
        return "  \(fixture)\(wer)\(exact)\(shape)\(keyUp)\(describeSuppression(record.suppression))"
    }

    /// The detail line under a row: what the streamed side actually showed before key-up. Zero
    /// partials is a **measured fact, not an assumption** — the key-up decode covers the full
    /// window, and the row says so with the number. With partials, the row shows what the
    /// sixty-second fixture's key-up decode actually cost vs the full batch.
    static func renderNotes(_ record: EquivalenceFixtureRecord) -> String? {
        let keyUp = record.keyUpElapsed.map { "\(milliseconds($0)) ms" } ?? "n/a"
        if record.partialsObserved == 0 {
            return "no partials before key-up — the key-up decode covers the full window (\(keyUp))"
        }
        let batch = record.batchElapsed.map { "\(milliseconds($0)) ms" } ?? "n/a"
        return "partials observed: \(record.partialsObserved) — key-up \(keyUp) vs batch \(batch)"
    }

    /// The verdict table: the header, then one line per fixture with its detail line beneath.
    static func renderTable(_ result: EquivalenceRunResult) -> String {
        var lines = ["  fixture          wer     exact  shape              key-up  suppression"]
        for fixture in result.fixtures {
            lines.append(renderRow(fixture))
            if let note = renderNotes(fixture) {
                lines.append("      \(note)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func shapeText(_ shape: TokenDiffShape) -> String {
        switch shape {
        case .identical: return "identical"
        case .prefixThenDiverge(let common): return "prefix-diverge(\(common))"
        case .wholesaleDrift: return "wholesale-drift"
        }
    }
}