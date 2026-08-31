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

/// Why a streamed-vs-batch equivalence run failed, named by the violated clause — the
/// ``RealEngineWERRunnerError`` shape: every failure carries the fixture name and, where one
/// exists, the partial ledger, so a real-run failure hands the re-baseline decision the data
/// instead of a bare name.
enum EquivalenceRealEngineRunnerError: Error, Equatable, CustomStringConvertible {
    /// The tolerance table names neither the fixture nor the `"clean"` fallback — a new fixture
    /// never defaults to a free pass.
    case missingTolerance(fixture: String)
    /// A transcript was attributed to an engine other than the one the run is for (invariant I1).
    case attributionMismatch(
        fixture: String, expected: EngineIdentity, actual: EngineIdentity)
    /// The streamed side yielded no final — a fixture whose side is missing is never fabricated
    /// into a verdict row.
    case noFinal(fixture: String, partialsObserved: Int)
    /// The streamed side yielded more than one final — the seam's contract is partials then
    /// exactly one final, and a comparison over two finals is not a comparison.
    case multipleFinals(fixture: String, finals: Int, partialsObserved: Int)

    var description: String {
        switch self {
        case .missingTolerance(let fixture):
            return "no tolerance for \(fixture) and no \"clean\" fallback in the table"
        case .attributionMismatch(let fixture, let expected, let actual):
            return "\(fixture): transcript attributed to \(actual.id), expected \(expected.id)"
        case .noFinal(let fixture, let partials):
            return "\(fixture): the stream yielded \(partials) partials and no final — "
                + "a missing side is void, never a fabricated row"
        case .multipleFinals(let fixture, let finals, let partials):
            return "\(fixture): the stream yielded \(finals) finals after \(partials) partials — "
                + "the seam's contract is exactly one final"
        }
    }
}

/// The fixture-driving harness (Phase (b) of the equivalence-measurement plan): one runner,
/// parameterized over `any ASREngine` — the ``RealEngineWERRunner`` split — that drives every
/// discovered fixture **twice**, batch `transcribe` and streamed (chunks → collect → final),
/// compares through ``StreamedVsBatchComparison``, prints the verdict table with the
/// suppression state beside every row, and **never throws on a blown tolerance** — the verdict
/// records, never gates.
///
/// The suppression read and the clock are **injected**, so the void-discipline and the key-up
/// accounting are headless-testable; the env-gated test is a thin shell over this body.
enum EquivalenceRealEngineRunner {

    /// Runs the comparison over `fixtures` and returns the run's record. Loud failures — a
    /// stream that yields zero or two finals, a misattributed transcript, a fixture with no
    /// tolerance — throw named errors; a blown tolerance is a **recorded** FAIL row, never a
    /// throw (the ``LatencyBenchmarkRealEngineTests`` charter).
    static func run(
        engine: any ASREngine,
        fixtures: [ASRFixtureCase],
        toleranceTable: [String: Double],
        suppression: () -> DarwinSuppression,
        clock: MonotonicClock
    ) async throws -> EquivalenceRunResult {
        var records: [EquivalenceFixtureRecord] = []
        for fixture in fixtures {
            records.append(
                try await record(
                    for: fixture, engine: engine, toleranceTable: toleranceTable,
                    suppression: suppression, clock: clock))
        }

        let verdict = EquivalenceRunVerdict.decide(records: records)
        let result = EquivalenceRunResult(fixtures: records, verdict: verdict)
        printRun(result, engine: engine, fixtures: fixtures)
        return result
    }

    // MARK: - One fixture

    private static func record(
        for fixture: ASRFixtureCase,
        engine: any ASREngine,
        toleranceTable: [String: Double],
        suppression: () -> DarwinSuppression,
        clock: MonotonicClock
    ) async throws -> EquivalenceFixtureRecord {
        // The loud-failure half of the tolerance table: a fixture with no tolerance and no
        // `"clean"` fallback is a broken run, never a free pass.
        guard
            let tolerance = ProvisionalEquivalenceTolerances.tolerance(
                for: fixture.name, in: toleranceTable)
        else {
            throw EquivalenceRealEngineRunnerError.missingTolerance(fixture: fixture.name)
        }

        let batchStart = clock.now
        let batch = try await engine.transcribe(fixture.buffer)
        let batchElapsed = clock.now - batchStart
        guard batch.engine == engine.identity else {
            throw EquivalenceRealEngineRunnerError.attributionMismatch(
                fixture: fixture.name, expected: engine.identity, actual: batch.engine)
        }

        // The streaming guard: a non-streaming engine would compare batch against batch, which
        // proves nothing — every row is VOID with the named reason (a pre-sibling ParakeetEngine
        // records VOID loudly, never a silent equality). No duration exists for a run that did
        // not happen.
        guard engine.supportsStreaming else {
            let row = StreamedVsBatchComparison.compare(
                fixtureName: fixture.name, batchText: batch.text, streamedFinalText: "")
            return EquivalenceFixtureRecord(
                row: row,
                verdict: StreamedVsBatchComparison.decide(
                    row: row, tolerance: tolerance,
                    preconditions: EquivalencePreconditions(engineStreams: false)),
                batchElapsed: nil,
                keyUpElapsed: nil,
                streamedElapsed: nil,
                partialsObserved: 0,
                suppression: suppression())
        }

        let sampleChunks = chunks(
            of: fixture.buffer.samples, size: EquivalenceMeasurementTargets.streamChunkSamples)
        // The last chunk's delivery instant, captured inside the producer — the honest anchor of
        // the key-up cost (the `finish()` decode). `@unchecked Sendable` for the ``BenchmarkClock``
        // reason: written by the stream's producer, read by the consuming task after the final,
        // serialized by the awaits between them — single-writer, sequential.
        let lastChunkStamp = LastChunkStamp()
        let streamedStart = clock.now
        let chunkStream = AsyncStream<VoccaCore.AudioBuffer> { continuation in
            for samples in sampleChunks {
                lastChunkStamp.at = clock.now
                continuation.yield(
                    VoccaCore.AudioBuffer(samples: samples, sampleRate: 16_000))
            }
            continuation.finish()
        }

        var partialsObserved = 0
        var finals: [Transcript] = []
        var finalAt: Duration?
        for try await transcript in engine.stream(chunkStream) {
            if transcript.isFinal {
                finals.append(transcript)
                finalAt = clock.now
            } else {
                partialsObserved += 1
            }
        }
        guard finals.count == 1 else {
            if finals.isEmpty {
                throw EquivalenceRealEngineRunnerError.noFinal(
                    fixture: fixture.name, partialsObserved: partialsObserved)
            }
            throw EquivalenceRealEngineRunnerError.multipleFinals(
                fixture: fixture.name, finals: finals.count, partialsObserved: partialsObserved)
        }
        let final = finals[0]
        guard final.engine == engine.identity else {
            throw EquivalenceRealEngineRunnerError.attributionMismatch(
                fixture: fixture.name, expected: engine.identity, actual: final.engine)
        }

        let state = suppression()
        let row = StreamedVsBatchComparison.compare(
            fixtureName: fixture.name, batchText: batch.text, streamedFinalText: final.text)
        let preconditions = EquivalencePreconditions(
            suppressionReadable: isReadable(state),
            engineStreams: true,
            batchPresent: true,
            streamedFinalPresent: true)
        return EquivalenceFixtureRecord(
            row: row,
            verdict: StreamedVsBatchComparison.decide(
                row: row, tolerance: tolerance, preconditions: preconditions),
            batchElapsed: batchElapsed,
            keyUpElapsed: finalAt.map { $0 - (lastChunkStamp.at ?? $0) },
            streamedElapsed: finalAt.map { $0 - streamedStart },
            partialsObserved: partialsObserved,
            suppression: state)
    }

    // MARK: - Chunking

    /// Splits the fixture's samples into chunks of `size`, the final remainder included. An
    /// empty buffer produces no chunks at all — the stream's empty-buffer policy answers it.
    static func chunks(of samples: [Float], size: Int) -> [[Float]] {
        guard !samples.isEmpty, size > 0 else { return [] }
        var result: [[Float]] = []
        var offset = 0
        while offset < samples.count {
            let end = min(offset + size, samples.count)
            result.append(Array(samples[offset..<end]))
            offset = end
        }
        return result
    }

    private static func isReadable(_ state: DarwinSuppression) -> Bool {
        if case .unreadable = state { return false }
        return true
    }

    // MARK: - The last-chunk stamp

    /// The last chunk's delivery instant, captured inside the chunk producer — the honest anchor
    /// of the key-up cost (the `finish()` decode). `@unchecked Sendable` for the
    /// ``BenchmarkClock`` reason: written by the stream's producer, read by the consuming task
    /// after the final arrives, serialized by the awaits between them — single-writer,
    /// sequential.
    private final class LastChunkStamp: @unchecked Sendable {
        var at: Duration?
    }

    // MARK: - The printed record

    private static func printRun(
        _ result: EquivalenceRunResult,
        engine: any ASREngine,
        fixtures: [ASRFixtureCase]
    ) {
        print("")
        print("== Streamed-vs-batch equivalence run (RECORDED, never gated) ==")
        print("engine: \(engine.identity.id) (supportsStreaming: \(engine.supportsStreaming))")
        print("fixtures: \(fixtures.map(\.name).joined(separator: ", "))")
        print(EquivalenceRowRenderer.renderTable(result))
        print("")
        print("transcripts (batch / streamed final):")
        for fixture in result.fixtures {
            print("  \(fixture.row.fixtureName):")
            print("    batch:   \(fixture.row.batchText)")
            print("    streamed: \(fixture.row.streamedFinalText)")
        }
        print("")
        print(EquivalenceRowRenderer.whisperExclusionNote)
        switch result.verdict {
        case .go:
            print("go/no-go: GO")
        case .noGo(let fixtures):
            print("go/no-go: NO-GO (fixtures: \(fixtures.joined(separator: ", ")))")
        case .void(let reasons):
            print("go/no-go: VOID (reasons: \(reasons.joined(separator: " | ")))")
        }
        print(
            "RECORDED, never gated: a blown tolerance never throws, and a FAIL here blocks "
                + "claiming the latency win, never shipping the feed.")
    }
}