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

/// The widget-only destination for streaming partial transcripts (C7, the
/// `widget-streaming` slice): the seam ``DictationPipeline/routeStreaming(chunks:target:sessionID:)``
/// emits every `isFinal == false` transcript's text to this sink, and nothing else in the loop
/// ever sees a partial.
///
/// Widget-only **by construction**: the pipeline holds the sink only to emit, decides nothing
/// about where the text goes, and the composition root wires it to the widget store's fold —
/// there is no second consumer in the loop to grow into. A partial must never reach the
/// injector (the pipeline's guard sees to that) and must never be presented as a final
/// transcript — `isFinal == false` is the boundary the widget renders provisional text behind.
///
/// The method is synchronous because emitting is fire-and-forget from the pipeline's point of
/// view: the partial has no decision attached to it (the reducer owns the widget's state), so
/// the seam adds no suspension to the streaming path.
public protocol PartialTranscriptSink: Sendable {
    /// Presents one provisional transcript's text — the partial as the engine produced it,
    /// never marked final, never injected anywhere.
    func presentPartial(_ partial: String)
}