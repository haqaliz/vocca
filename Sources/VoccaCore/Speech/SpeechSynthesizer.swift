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

/// The pluggable text-to-speech boundary (`ARCHITECTURE.md:301-305`).
///
/// Every speech adapter is this protocol and nothing else: Kokoro-82M at C9, the macOS
/// `AVSpeechSynthesizer` as the shipped second implementation, a hosted provider behind the
/// same seam later. The input is text, the output is a stream of ``AudioChunk`` PCM — and
/// cancellation is a **first-class operation**, because C10's barge-in depends on halting
/// mid-utterance (`CAPABILITY_ROADMAP.md:248`).
///
/// ## The seam's contract
///
/// - **Attribution.** Every chunk a caller hears came from the synthesizer whose ``identity``
///   that is. The identity is exposed on the seam itself — the speech twin of the ASR seam's
///   non-optional ``Transcript/engine`` — so the consumer can name what it is driving, and
///   two engines with different `engineID`s are different values.
/// - **Chunks arrive in order, as sentences complete.** ``speak(_:)`` yields chunks in the
///   order they were rendered; the sentence-level chunker (`SentenceChunker`) is what makes
///   "speech begins before the full reply is synthesized" the shape of the seam rather than a
///   promise of the pipeline.
/// - **Empty text is an empty stream.** `speak("")` yields no chunks and never throws — the
///   speech twin of the ASR seam's empty-buffer policy: nothing to say is an answer, not an
///   error.
/// - **`cancel()` halts output within ≤50 ms.** The stream terminates promptly after the
///   cancel returns, and **no chunk arrives after it** — a barge-in that leaks the tail of
///   the utterance is a barge-in that does not work.
/// - **Cancel-then-reinvoke is safe.** It is always legal to call ``cancel()`` and immediately
///   ``speak(_:)`` again: no deadlock, no session corruption, and the second stream renders
///   fully rather than resuming the cancelled one.
public protocol SpeechSynthesizer: Sendable {
    /// Which synthesizer this is: the engine key (`"kokoro-82m"`, `"system"`) plus the named
    /// voice, if any. Every chunk the caller hears is attributable to this value.
    var identity: VoiceIdentity { get }

    /// Renders `text` into a stream of PCM chunks.
    ///
    /// Chunks arrive in rendering order; `speak("")` yields nothing and never throws. The
    /// stream terminates on its own when the text is fully rendered.
    func speak(_ text: String) -> AsyncThrowingStream<AudioChunk, Error>

    /// Halts any in-flight ``speak(_:)``.
    ///
    /// Must halt output **within ≤50 ms** — the barge-in budget
    /// (`CAPABILITY_ROADMAP.md:248`) — and the cancelled stream must terminate promptly with
    /// no chunk after the cancel. Safe to cancel and immediately re-invoke: the next
    /// ``speak(_:)`` renders fully, with no deadlock and no session corruption.
    func cancel() async
}