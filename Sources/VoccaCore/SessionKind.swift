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

/// What kind of session a record is of — real work, or the setup demo.
///
/// Onboarding's TRY IT runs through the **production** ledger: the composition root swaps only
/// the injector (`AppBootstrap.injectorComposition(completionFlag:)`) and hands both branches the
/// same recorder, so a setup demo and a real dictation arrive at the same records with the same
/// classes, spans and engine attribution. Without this, nothing on the record says which
/// composition delivered it.
///
/// It is a measurement distinction, never a behavioural one — no path branches on it, and the
/// pipeline's outcome table is the same table for both. Two facts make it load-bearing:
///
/// - The onboarding injector never holds. The sink owns delivery, so a refused TRY IT reaches the
///   failsafe arm with the journal holding nothing and finalizes ``SessionOutcomeClass/lost`` —
///   the same class a real dictation gets when its transcript vanishes. `ROADMAP.md:95` fixes
///   transcript loss at zero with no acceptable non-zero value, and a setup failure nobody had
///   typed a word into yet must stay visible without being counted against it.
/// - `ROADMAP.md:102`'s gate is about dictating as the **primary text-input method** for seven
///   consecutive days. A day whose only session was a setup demo is not a day of that, so a
///   count that cannot separate the two cannot answer the question the gate asks.
///
/// Fixed per composition, like the recorder and the clock: the choice is made once, where the
/// injector is chosen, and never at session time.
public enum SessionKind: Sendable, Equatable {
    /// Real work — the shipping ladder delivered it, and it counts towards P0's daily-use gate.
    case dictation
    /// The onboarding window's TRY IT demo — recorded in full, counted separately.
    case onboarding
}
