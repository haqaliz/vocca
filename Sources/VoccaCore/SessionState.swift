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

/// Where a dictation session is in its life: `idle → recording → ending → idle`.
///
/// Three states and no `default:` anywhere they are switched. A fourth state must therefore be a
/// compile error at every decision point rather than something that quietly inherits an existing
/// branch — the failure mode being guarded against is a state in which nobody has decided whether
/// the microphone is open.
public enum SessionState: Sendable, Hashable, CaseIterable {
    /// No capture in flight. The microphone is closed.
    case idle

    /// Capture is running. Exactly one stop funnel leads out of here.
    case recording

    /// A stop has been decided and the captured audio is on its way downstream. Distinct from
    /// `idle` because further events must not start a new session while the previous one is still
    /// handing off — that is the double-start bug, and it is what makes this a state rather than
    /// a boolean.
    case ending
}
