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
@testable import VoccaSpeech

/// The Kokoro engine's headless pins (`kokoro-binding`/`engine-binding` spec acceptance 1) — the
/// conformance's contract, written before the conformance exists.
///
/// Everything here runs in CI with **no model and no network**: the identity, the init-purity
/// promise (a nonexistent model directory must not throw — the port's own init would), the
/// empty-speak short-circuit (zero chunks, no port touch), the absent-models error mapping
/// (asserted by identity, never a crash), the cancel-with-nothing-in-flight no-op, and the
/// sample→`AudioChunk` conversion over constructed `[Float]` values.
final class KokoroEngineTests: XCTestCase {

    /// A model directory that does not exist — the headless stand-in for "models not provisioned".
    private var nonexistentDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-kokoro-headless-\(UUID().uuidString)")
    }

    // MARK: - Identity

    /// `identity` = `engineID: "kokoro-82m"` with the configured voice name — and it differs from
    /// the system engine's identity, so downstream attribution can tell the two engines apart.
    func testIdentityNamesTheKokoroEngineAndTheConfiguredVoice() {
        let synth = KokoroEngine(modelDirectory: nonexistentDirectory, voice: "af_heart", rate: nil)

        XCTAssertEqual(
            synth.identity.engineID, "kokoro-82m",
            "the Kokoro engine's engine key is \"kokoro-82m\" — the seam's own vocabulary")
        XCTAssertEqual(
            synth.identity.voiceName, "af_heart",
            "the voice name is the configured voice, as plain data")
        XCTAssertEqual(
            synth.identity, VoiceIdentity(engineID: "kokoro-82m", voiceName: "af_heart"),
            "the identity is the whole value downstream attribution matches on")
        XCTAssertNotEqual(
            synth.identity, SystemSynthesizer(voiceIdentifier: nil).identity,
            "two engines with different engineIDs are different values — attribution must not "
                + "confuse the Kokoro engine with the system engine")
    }

    // MARK: - Init purity

    /// Constructing with a **nonexistent** directory does not throw (a non-throwing init makes
    /// that trivially true — the pin is that nothing about the port is constructed here): the
    /// port's own `KokoroCoreML.KokoroEngine` init would throw `modelsNotAvailable` and spawn
    /// model work; the adapter's init stores plain data only. This is the probe's contract.
    func testInitWithANonexistentDirectoryDoesNotThrow() {
        let synth = KokoroEngine(modelDirectory: nonexistentDirectory, voice: "af_heart", rate: nil)
        XCTAssertEqual(
            synth.identity.engineID, "kokoro-82m",
            "the constructed engine is the Kokoro engine — the init ran to completion")
    }

    // MARK: - Empty speak

    /// `speak("")` over a nonexistent directory yields zero chunks and never throws — the seam's
    /// empty-stream policy short-circuits before any port touch.
    func testEmptySpeakYieldsNothingAndNeverThrows() async throws {
        let synth = KokoroEngine(modelDirectory: nonexistentDirectory, voice: "af_heart", rate: nil)
        var iterator = synth.speak("").makeAsyncIterator()

        let first = try await iterator.next()
        XCTAssertNil(first, "empty text yields no chunks")
        let second = try await iterator.next()
        XCTAssertNil(second, "the empty stream terminates — no chunk arrives later")
    }

    // MARK: - Absent-models error

    /// A non-empty speak over a nonexistent directory makes the stream **throw the recorded
    /// mapped error** — `KokoroEngineError.modelsUnavailable` carrying the directory — never a
    /// crash, and never a silent empty stream.
    func testSpeakOverANonexistentDirectoryThrowsTheRecordedMappedError() async throws {
        let directory = nonexistentDirectory
        let synth = KokoroEngine(modelDirectory: directory, voice: "af_heart", rate: nil)
        var received: [AudioChunk] = []

        do {
            for try await chunk in synth.speak("Hello there.") {
                received.append(chunk)
            }
            XCTFail("a speak over a nonexistent model directory must throw, not finish silently")
        } catch let error as KokoroEngineError {
            guard case .modelsUnavailable(let named) = error else {
                return XCTFail("expected the mapped models-unavailable error, got \(error)")
            }
            XCTAssertEqual(
                named, directory,
                "the mapped error carries the directory the models were absent from")
        } catch {
            XCTFail("the stream threw an unmapped error: \(error)")
        }

        XCTAssertTrue(
            received.isEmpty,
            "no chunk may be yielded before the mapped error — a partial sentence is never delivered")
    }

    // MARK: - Cancel with nothing in flight

    /// `cancel()` with nothing in flight is a safe no-op — no stream to terminate, no state to
    /// corrupt — and a subsequent empty-speak still yields nothing.
    func testCancelWithNothingInFlightIsASafeNoOpAndEmptySpeakStillYieldsNothing() async throws {
        let synth = KokoroEngine(modelDirectory: nonexistentDirectory, voice: "af_heart", rate: nil)

        await synth.cancel()
        await synth.cancel()

        var iterator = synth.speak("").makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertNil(first, "the post-cancel empty-speak still yields nothing")
    }

    // MARK: - Sample conversion

    /// `audioChunk(fromSamples:)` converts `[Float]` into the seam's chunk shape: Float32
    /// little-endian bytes via `bitPattern` (4 bytes per sample), 24 kHz mono, duration =
    /// count ÷ 24000.
    func testSampleConversionProducesLittleEndianFloat32PCM() throws {
        let samples: [Float] = [1.0, -1.0, 0.5, 0.0]

        let chunk = try XCTUnwrap(KokoroEngine.audioChunk(fromSamples: samples))

        XCTAssertEqual(
            chunk.bytes.count, 4 * samples.count,
            "the payload is one little-endian Float32 per sample — 4 bytes each")
        XCTAssertEqual(chunk.sampleRate, 24_000, "the port renders at 24 kHz — the chunk names it")
        XCTAssertEqual(chunk.channelCount, 1, "the port renders mono — the chunk names it")
        XCTAssertEqual(
            chunk.duration, Double(samples.count) / 24_000, accuracy: 1e-9,
            "duration is samples ÷ rate, computed by the producer")
        let expectedFirst = withUnsafeBytes(of: samples[0].bitPattern.littleEndian) { Array($0) }
        XCTAssertEqual(
            Array(chunk.bytes.prefix(4)), expectedFirst,
            "the first sample's bytes are its Float32 bitPattern, little-endian — the exact PCM "
                + "format the consumer decodes")
    }

    /// An empty sample array converts to no chunk (`nil`), never a zero-duration chunk — the
    /// per-chunk-duration > 0 pin of the real-engine suite depends on it.
    func testEmptySampleArrayConvertsToNoChunk() {
        XCTAssertNil(
            KokoroEngine.audioChunk(fromSamples: []),
            "zero samples is not a zero-duration chunk — it is no chunk at all")
    }
}