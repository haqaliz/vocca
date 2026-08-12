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

/// Where the widget's waveform comes from: the current input level, in 0...1.
///
/// The seam is deliberately one synchronous read and nothing else — the widget's ~60 ms refresh
/// (`spec.md` open question; plan-level cadence) calls this and draws, never reaching into the
/// capture graph. The real conformance lives in `VoccaAudio` (`MicrophoneLevelSource`, the
/// `widget-live-states` Task 4): an atomic peak **published** by the capture graph's realtime
/// callback — which must never allocate or block, the repo's realtime discipline — and read on the
/// main actor. A test fake conforms here in `HarnessTests`, which is what makes every widget
/// decision about the level headless.
///
/// The contract has two halves. **The value is 0...1**: a conformance that lies about the range
/// makes the waveform lie about the voice, and while ``WaveformMapping`` clamps defensively, the
/// clamp is not a licence. **The read never blocks the caller**: `latestLevel()` returns a value
/// the callback already published — a read that reached back into the graph would block the
/// widget's main-actor refresh on a realtime structure.
public protocol LiveLevelSource: Sendable {
    /// The newest published input level, 0...1, as of this instant.
    func latestLevel() -> Float
}
