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

/// The deterministic rules engine (`ARCHITECTURE.md:511`): a pure function over
/// `(String, [ReplacementRule]) -> String` — filler removal, sentence segmentation and terminal
/// punctuation, capitalization, spoken-punctuation commands, number/unit normalization, then user
/// dictionary rules in declared order. Pure means table-driven tests (`RulesCleanupTests`).
///
/// The engine is deliberately **not** a `CleanupProvider` conformance: it is the pure function the
/// conformer (`ShippingCleanup`, pipeline-wiring's M6) composes the seam's context down to. It
/// reads `String`/`[ReplacementRule]` only — no IO, no clock, no network, no randomness; every
/// stage returns a new `String` and never mutates its input. Output is byte-identical across
/// machines and process invocations: explicit tables only, no `Locale`, no `NumberFormatter`, no
/// `String(format:)` (`spec.md` `## Isolation`).
///
/// The adapter shape follows `VoccaAudio`'s precedent (the seam-owned-vocabulary enum), and the
/// module-move precedent the boundary suite documents (`ModuleBoundaryTests`): VoccaText imports
/// `VoccaCore` and nothing else — beyond it, stdlib only.
public enum RulesCleanup {
    /// The composed pipeline, signature per `ARCHITECTURE.md:511`.
    ///
    /// The six stages run in the fixed order declared below. The order deliberately reorders
    /// `ARCHITECTURE.md`'s listing: the spoken-command stage must produce its symbols *before*
    /// segmentation so the boundary exists (`spec.md` `## In scope` 2); the observable order of
    /// effects matches `ARCHITECTURE.md:511`. The dictionary arrives in declared order
    /// (`ReplacementRule` — order is the contract) and runs after the built-ins.
    public static func clean(_ input: String, dictionary: [ReplacementRule]) -> String {
        input
    }

    /// Stage 1 — filler removal, frequency-tuned rather than blanket (`spec.md` B1).
    public static func removeFillers(_ input: String) -> String {
        input
    }

    /// Stage 2 — spoken-punctuation commands resolved to their symbols, including N2 literal
    /// tokens (`spec.md` B4, B9).
    public static func resolveSpokenCommands(_ input: String) -> String {
        input
    }

    /// Stage 3 — sentence segmentation and terminal punctuation (`spec.md` B2).
    public static func segmentAndTerminate(_ input: String) -> String {
        input
    }

    /// Stage 4 — sentence-initial capitalization (`spec.md` B3).
    public static func capitalizeSentences(_ input: String) -> String {
        input
    }

    /// Stage 5 — bounded number/unit normalization (`spec.md` B5).
    public static func normalizeNumbers(_ input: String) -> String {
        input
    }

    /// Stage 6 — user dictionary rules in declared order (`spec.md` B7, B8).
    public static func applyDictionary(_ input: String, rules: [ReplacementRule]) -> String {
        input
    }
}
