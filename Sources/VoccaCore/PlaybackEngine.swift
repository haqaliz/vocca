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

/// The duckable voice-loop output (`ARCHITECTURE.md:107` — "Playback/ # duckable output for
/// barge-in", the C10 P3 voice loop's playback half).
///
/// The barge-in budget decomposes as **VAD frame ~30 ms + `SpeechSynthesizer.cancel()` ≤50 ms +
/// this seam's duck ramp (default 20 ms, ``PlaybackLevel``) + stop margin ≤ 200 ms** — the
/// composed gate is the `barge-in-loop` aspect's acceptance; this seam's own term is the ramp,
/// and it consumes the shipped ≤50 ms cancel contract rather than re-litigating it
/// (`CAPABILITY_ROADMAP.md:248`). Ducking is a **first-class operation**: a barge-in ducks the
/// level before it cuts, so the halt is a duck, not a click.
///
/// ## The seam's contract
///
/// - **`play` returns after drain, not after enqueue.** The reply's tail must not still be
///   sounding when the loop goes back to listening (echo). `play` of an empty stream returns
///   without starting the output and never throws — nothing to play is an answer.
/// - **A second `play` while one is active supersedes it**: the first session is halted, the
///   second renders fully. There is no handle type — the only thing a handle could carry is
///   completion observation, and the awaited `play` already carries it.
/// - **The stream's format is fixed by its first chunk.** The producers ship uniform-format
///   streams (Float32 at a named rate and channel count); a chunk whose format differs is a
///   stream failure, not something to guess at.
/// - **`duck()` ramps the level to the duck target and playback continues.** Idempotent; a no-op
///   when no session is active (it never pre-arms the next session).
/// - **`cancelToSilence()` halts to silence within the barge-in budget**: the level ramps down
///   (the duck) and the output stops — silence at `rampDuration + stop`, never a cut. Idempotent;
///   a no-op when no session is active. **Cancel-then-play is safe**: the next `play` renders
///   fully — the `SpeechSynthesizer` twin of "cancel-then-reinvoke is safe".
/// - **`tearDown()` releases the output.** Idempotent, synchronous, non-throwing — the
///   `CaptureGraphSeam.stop()` release contract ("do not return until it is released"). A later
///   `play` reopens.
public protocol PlaybackEngine: Sendable {
    /// Plays `stream` to the output. Returns when every chunk has been rendered to silence
    /// (drained), when ``cancelToSilence()`` halts it, or — throwing — when the stream fails or
    /// the output cannot start. `play` with an empty stream returns without starting the output.
    /// A second `play` while one is active supersedes it (the first is halted).
    func play(_ stream: AsyncThrowingStream<AudioChunk, Error>) async throws

    /// Ramps the output level to the duck target; playback continues. Idempotent; a no-op when
    /// no session is active (it never pre-arms the next session).
    func duck() async

    /// Halts to silence within the barge-in budget: ramps the level down (the duck) and stops.
    /// Idempotent; a no-op when no session is active. Cancel-then-play is safe: the next `play`
    /// renders fully (the `SpeechSynthesizer` twin of "cancel-then-reinvoke is safe").
    func cancelToSilence() async

    /// Releases the output device. Idempotent, synchronous, non-throwing — the
    /// `CaptureGraphSeam.stop()` release contract ("do not return until it is released"). A later
    /// `play` reopens.
    func tearDown()
}