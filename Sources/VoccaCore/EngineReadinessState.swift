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

/// **Moved here from `AppBootstrap.swift` by the `speech-tab` aspect**, and the reason is the
/// whole of `spec.md` R6. Three surfaces now report this one fact — the Speech tab, the menu bar
/// icon, and the press the pill renders — and two of them live in `VoccaUI`, which may import only
/// `VoccaCore`. Leaving the vocabulary in the composition root would have forced `VoccaUI` to
/// mirror it, and a mirrored enum is two answers to one question waiting to drift: the exact shape
/// of the bug M11 names. `EngineReadiness` — the gate itself, and the closed set of things that
/// may open it — stays in `AppBootstrap.swift`, where `EngineReadinessTests` still scans it.
///
/// **What the engine is doing, for the surfaces that report it** — the three-way answer PRD M11
/// asks for.
///
/// Two states are enough for the readiness *gate*, which only ever asks "may the microphone open?".
/// They are not enough for the person. After an engine switch the model is already on disk, nothing
/// is wrong, and the only true thing to say is "a moment"; a failed load is a wait that will never
/// end. Reporting both as one state is how an in-between window comes to look like a failure, which
/// M11 names as this repository's dominant bug class — an `LSUIElement` app where a successful
/// launch and a dead one look exactly the same.
///
/// The gate is closed for everything but ``ready``, so a fourth state added here cannot accidentally
/// open a microphone.
public enum EngineReadinessState: Sendable, Hashable {
    /// No preparation is in flight: none has started, or the last one failed. The next press is
    /// refused, and waiting will not change that.
    case unavailable
    /// A preparation is running right now. The next press is refused, and waiting *is* the remedy.
    case preparing
    /// The selected engine is prepared. The microphone may open.
    case ready
}
